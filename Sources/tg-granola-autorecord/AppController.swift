import AppKit
import AutorecordCore
import Foundation

/// The running app: no windows, a status alert when opened, and the core agent ticking once a second.
final class AppController: NSObject, NSApplicationDelegate {
    private let paths: Paths
    private let queue = DispatchQueue(label: "\(Product.bundleID).agent")
    private lazy var notifications = Notifications { [weak self] action in self?.handle(action) }
    private var agent: Agent?
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()
    private var notificationsAllowed: Bool?
    private var lastStatusWrite = Date.distantPast
    private var lastPhase: CallTracker.Phase?
    private var hadOwnedRecording = false

    init(paths: Paths) {
        self.paths = paths
    }

    static func run(paths: Paths) -> Never {
        let app = NSApplication.shared
        let controller = AppController(paths: paths)
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    // MARK: NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.useFile(paths.log)
        // The notification delegate must be in place before launching finishes, so that
        // a tap on a notification action that launched the app still reaches it.
        notifications.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.acquire(at: paths.lock) else {
            Log.info("another copy is already running, quitting this one")
            NSApp.terminate(nil)
            return
        }
        Log.info("\(Product.name) \(Product.version) started, pid \(ProcessInfo.processInfo.processIdentifier)")

        guard StatusAlert.isInApplicationsFolder() else {
            Log.warn("not in Applications: \(Bundle.main.bundlePath)")
            StatusAlert.askToMoveToApplications()
            NSApp.terminate(nil)
            return
        }

        if Preferences.turnedOffByUser {
            guard StatusAlert.offerToTurnOn() else {
                NSApp.terminate(nil)
                return
            }
            Preferences.turnedOffByUser = false
            Log.info("turned on by the user")
        }

        let registrationError = LoginItem.ensureRegistered()
        if let registrationError {
            Log.warn("could not add the login item: \(registrationError.localizedDescription)")
        }
        startAgent()

        let firstRun = !Preferences.hasCompletedFirstRun
        Preferences.hasCompletedFirstRun = true
        let report = SetupReport.current(registrationError: registrationError)
        if firstRun || report.hasProblems {
            DispatchQueue.main.async { self.presentStatus(report) }
        }
    }

    /// Opening the app again while it runs shows the status.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentStatus(SetupReport.current())
        return false
    }

    // MARK: Agent

    private func startAgent() {
        let config = loadConfig()
        Log.info("watching \(config.apps.joined(separator: ", "))")
        if !GranolaAccessibility.isTrusted(prompt: false) {
            Log.warn("no Accessibility access yet: stopping by button stays off until it is allowed")
        }
        let granola = GranolaApp(config: config, homeDirectory: paths.homeDirectory)
        queue.async {
            self.agent = Agent(
                config: config,
                audio: SystemAudio(),
                granola: granola,
                stopRoutes: granola,
                presenter: self.notifications,
                ownedRecording: FileOwnedRecordingStore(url: self.paths.ownedRecording),
                time: SystemTime(),
                log: Log.info
            )
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func loadConfig() -> Config {
        do {
            return try ConfigLoader.load(from: paths.config)
        } catch {
            Log.error("cannot read \(paths.config.path): \(error). Using the defaults.")
            notifications.post(
                id: "config-error",
                title: "Settings file has an error",
                body: "Using the defaults. Run `\(Product.command) doctor` for details."
            )
            return .default
        }
    }

    private func tick() {
        agent?.tick()
        afterAgentWork()
    }

    private func handle(_ action: Notifications.Action) {
        switch action {
        case .stopRecording:
            queue.async {
                self.agent?.requestStop()
                self.afterAgentWork()
            }
        case .openGranola:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Granola.bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openAccessibilitySettings:
            SystemSettings.openAccessibility()
        }
    }

    private func presentStatus(_ report: SetupReport) {
        guard StatusAlert.show(report) == .turnOff else { return }
        Log.info("turned off by the user")
        Preferences.turnedOffByUser = true
        do {
            try LoginItem.service.unregister()
        } catch {
            Log.warn("could not remove the login item: \(error.localizedDescription)")
        }
        queue.sync {
            timer?.cancel()
            FileOwnedRecordingStore(url: paths.ownedRecording).save(nil)
        }
        NSApp.terminate(nil)
    }

    /// Runs on the agent queue after anything that may change the agent's state.
    private func afterAgentWork() {
        guard let agent else { return }
        let owns = agent.tracker.ownedRecordingStartedAt != nil
        if hadOwnedRecording && !owns {
            notifications.removeRecordingNotification()
        }
        hadOwnedRecording = owns

        let phase = agent.tracker.phase
        let now = Date()
        guard phase != lastPhase || now.timeIntervalSince(lastStatusWrite) >= 10 else { return }
        lastPhase = phase
        lastStatusWrite = now
        notifications.checkAllowed { [weak self] allowed in
            self?.queue.async { self?.notificationsAllowed = allowed }
        }
        let status = AgentStatus(
            version: Product.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            updatedAt: now,
            phase: phase.description,
            accessibilityTrusted: GranolaAccessibility.isTrusted(prompt: false),
            notificationsAllowed: notificationsAllowed,
            lastEvent: agent.lastEvent
        )
        do {
            try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            try AgentStatus.encoder().encode(status).write(to: paths.status, options: .atomic)
        } catch {
            Log.warn("could not write status: \(error)")
        }
    }
}

/// Keeps the start time of the recording the app is responsible for across restarts.
struct FileOwnedRecordingStore: OwnedRecordingStore {
    let url: URL

    private struct Record: Codable {
        var recordingStartedAt: Date
    }

    func load() -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? AgentStatus.decoder().decode(Record.self, from: data).recordingStartedAt
    }

    func save(_ recordingStartedAt: Date?) {
        guard let recordingStartedAt else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AgentStatus.encoder().encode(Record(recordingStartedAt: recordingStartedAt)).write(to: url, options: .atomic)
        } catch {
            Log.warn("could not remember the recording: \(error)")
        }
    }
}

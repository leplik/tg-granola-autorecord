import AppKit
import AutorecordCore
import Foundation

/// The long-running agent process: an accessory app with no UI that ticks the core agent once a second.
final class AgentController {
    private let paths: Paths
    private let queue = DispatchQueue(label: "\(Product.bundleID).agent")
    private var notifications: Notifications!
    private var agent: Agent!
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()
    private var notificationsAllowed: Bool?
    private var lastStatusWrite = Date.distantPast
    private var lastPhase: CallTracker.Phase?
    private var hadOwnedRecording = false

    init(paths: Paths) {
        self.paths = paths
    }

    func run() -> Never {
        Log.useFile(paths.log)
        Log.info("\(Product.name) \(Product.version) started, pid \(ProcessInfo.processInfo.processIdentifier)")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        notifications = Notifications { [weak self] action in self?.handle(action) }
        notifications.activate()

        let config = loadConfig()
        Log.info("watching \(config.apps.joined(separator: ", "))")

        if !GranolaAccessibility.isTrusted(prompt: true) {
            Log.warn("no Accessibility permission yet: stopping by button stays off until it is granted")
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
            self.scheduleTicks()
        }

        app.run()
        exit(0)
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

    private func scheduleTicks() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        agent.tick()
        afterAgentWork()
    }

    private func handle(_ action: Notifications.Action) {
        switch action {
        case .stopRecording:
            queue.async {
                self.agent.requestStop()
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

    /// Runs on the agent queue after anything that may change the agent's state.
    private func afterAgentWork() {
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
        writeStatus(phase: phase, now: now)
    }

    private func writeStatus(phase: CallTracker.Phase, now: Date) {
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

/// Keeps the start time of the recording the agent is responsible for across restarts.
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

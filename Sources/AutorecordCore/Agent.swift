import Foundation

public protocol AudioSource {
    func snapshot() -> [AudioProcessState]
}

public protocol GranolaLauncher {
    func isInstalled() -> Bool
    func isFrontmost() -> Bool
    func startNewNote() throws
}

public enum StartFailure: Equatable, Sendable {
    case couldNotOpenGranola
    case didNotStartRecording
}

/// Something the user should hear about. The executable turns these into notifications.
public enum AgentNotice: Equatable, Sendable {
    case recordingStarted
    case granolaNotInstalled
    case startFailed(StartFailure)
    case stopFailed(ButtonPressResult)
    case recordingStoppedByGranola
}

public protocol NoticePresenter {
    func present(_ notice: AgentNotice)
}

public protocol OwnedRecordingStore {
    func load() -> Date?
    func save(_ recordingStartedAt: Date?)
}

/// Runs the tracker against the real world: observes, acts, notifies and remembers what it owns.
/// Not thread-safe; the caller runs every method on one serial queue.
public final class Agent {
    public static let startWait: TimeInterval = 45
    /// A remembered recording older than this is not resumed after a restart.
    public static let ownedRecordingMaxAge: TimeInterval = 12 * 3600

    public private(set) var tracker: CallTracker
    public private(set) var lastEvent: String?

    private let config: Config
    private let watchedApps: Set<String>
    private let audio: AudioSource
    private let granola: GranolaLauncher
    private let stopRoutes: StopRoutes
    private let presenter: NoticePresenter
    private let ownedRecording: OwnedRecordingStore
    private let time: TimeSource
    private let log: (String) -> Void
    private var savedOwnership: Date?
    private var loggedPhase: CallTracker.Phase

    public init(
        config: Config,
        audio: AudioSource,
        granola: GranolaLauncher,
        stopRoutes: StopRoutes,
        presenter: NoticePresenter,
        ownedRecording: OwnedRecordingStore,
        time: TimeSource,
        log: @escaping (String) -> Void
    ) {
        self.config = config
        self.watchedApps = Set(config.apps)
        self.audio = audio
        self.granola = granola
        self.stopRoutes = stopRoutes
        self.presenter = presenter
        self.ownedRecording = ownedRecording
        self.time = time
        self.log = log

        let restored = Agent.resumableRecording(
            stored: ownedRecording.load(),
            now: time.now,
            granolaRecording: AudioSignals.isGranolaRecording(audio.snapshot())
        )
        tracker = CallTracker(
            startDelay: config.startDelaySeconds,
            endGrace: config.endGraceSeconds,
            restoredRecordingStartedAt: restored
        )
        loggedPhase = tracker.phase
        savedOwnership = restored
        ownedRecording.save(restored)
        if let restored {
            log("resumed responsibility for the recording started at \(restored)")
        }
    }

    static func resumableRecording(stored: Date?, now: Date, granolaRecording: Bool) -> Date? {
        guard let stored, granolaRecording, stored <= now, now.timeIntervalSince(stored) < ownedRecordingMaxAge else {
            return nil
        }
        return stored
    }

    /// One observation and whatever it leads to. Call about once a second.
    public func tick() {
        let snapshot = audio.snapshot()
        let observation = Observation(
            now: time.now,
            signal: AudioSignals.callSignal(snapshot, watchedApps: watchedApps),
            granolaRecording: AudioSignals.isGranolaRecording(snapshot),
            granolaFrontmost: granola.isFrontmost()
        )
        let actions = tracker.step(observation)
        logPhase(context: "call signal: \(observation.signal.rawValue), Granola recording: \(observation.granolaRecording)")
        actions.forEach(perform)
        persistOwnership()
    }

    /// The user asked to stop the current recording, e.g. from the notification.
    public func requestStop() {
        guard let action = tracker.stopRequestedByUser() else {
            log("stop requested, but there is no recording of ours to stop")
            return
        }
        log("stop requested by the user")
        logPhase(context: nil)
        perform(action)
        persistOwnership()
    }

    private func perform(_ action: TrackerAction) {
        switch action {
        case .startRecording:
            start()
        case .stopRecording(let startedAt):
            stop(recordingStartedAt: startedAt)
        case .recordingStoppedExternally(let startedAt, let likelyByUser):
            let seconds = Int(time.now.timeIntervalSince(startedAt))
            if likelyByUser {
                note("Granola stopped recording after \(seconds) s while it was the frontmost app, most likely by hand")
            } else {
                note("Granola stopped recording after \(seconds) s on its own")
                presenter.present(.recordingStoppedByGranola)
            }
        }
        logPhase(context: nil)
    }

    private func start() {
        guard granola.isInstalled() else {
            note("call detected, but Granola is not installed")
            presenter.present(.granolaNotInstalled)
            tracker.startFailed()
            return
        }
        log("call detected, asking Granola to start a note")
        do {
            try granola.startNewNote()
        } catch {
            note("could not open Granola: \(error)")
            presenter.present(.startFailed(.couldNotOpenGranola))
            tracker.startFailed()
            return
        }
        let started = poll(timeout: Self.startWait, time: time) {
            AudioSignals.isGranolaRecording(audio.snapshot())
        }
        guard started else {
            note("Granola did not start recording within \(Int(Self.startWait)) s")
            presenter.present(.startFailed(.didNotStartRecording))
            tracker.startFailed()
            return
        }
        note("Granola started recording the call")
        tracker.startSucceeded(at: time.now)
        if config.notifyOnStart { presenter.present(.recordingStarted) }
    }

    private func stop(recordingStartedAt: Date) {
        log("stopping Granola")
        let outcome = StopSequence(routes: stopRoutes, time: time, log: log).run(recordingStartedAt: recordingStartedAt)
        note("stop finished: \(outcome)")
        if case .failed(let reason) = outcome { presenter.present(.stopFailed(reason)) }
        tracker.stopFinished()
    }

    private func note(_ message: String) {
        log(message)
        lastEvent = message
    }

    private func logPhase(context: String?) {
        guard tracker.phase != loggedPhase else { return }
        log("\(loggedPhase) -> \(tracker.phase)" + (context.map { " (\($0))" } ?? ""))
        loggedPhase = tracker.phase
    }

    private func persistOwnership() {
        let current = tracker.ownedRecordingStartedAt
        guard current != savedOwnership else { return }
        ownedRecording.save(current)
        savedOwnership = current
    }
}

/// What the running agent reports about itself, for `doctor`.
public struct AgentStatus: Codable, Equatable, Sendable {
    public var version: String
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var phase: String
    public var accessibilityTrusted: Bool
    public var notificationsAllowed: Bool?
    public var lastEvent: String?

    public init(version: String, pid: Int32, startedAt: Date, updatedAt: Date, phase: String, accessibilityTrusted: Bool, notificationsAllowed: Bool?, lastEvent: String?) {
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.accessibilityTrusted = accessibilityTrusted
        self.notificationsAllowed = notificationsAllowed
        self.lastEvent = lastEvent
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

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

/// The recording the agent is responsible for, with a heartbeat that shows the agent was alive recently.
public struct OwnedRecord: Codable, Equatable, Sendable {
    public var recordingStartedAt: Date
    public var heartbeatAt: Date

    public init(recordingStartedAt: Date, heartbeatAt: Date) {
        self.recordingStartedAt = recordingStartedAt
        self.heartbeatAt = heartbeatAt
    }
}

public protocol OwnedRecordingStore {
    func load() -> OwnedRecord?
    func save(_ record: OwnedRecord?)
}

/// Runs the tracker against the real world: observes, acts, notifies and remembers what it owns.
/// Not thread-safe; the caller runs every method on one serial queue.
public final class Agent {
    public static let startWait: TimeInterval = 45
    /// How often the owned-recording heartbeat is refreshed while a recording runs.
    public static let heartbeatInterval: TimeInterval = 30
    /// A restarted agent resumes a recording only if the previous one was alive this recently.
    /// Covers restarts and upgrades, but not a file left behind by a crash hours ago.
    public static let resumeWindow: TimeInterval = 120

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
    private var savedRecord: OwnedRecord?
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

        let resumed = Agent.resumableRecording(
            stored: ownedRecording.load(),
            now: time.now,
            granolaRecording: AudioSignals.isGranolaRecording(audio.snapshot())
        )
        tracker = CallTracker(
            startDelay: config.startDelaySeconds,
            endGrace: config.endGraceSeconds,
            restoredRecordingStartedAt: resumed?.recordingStartedAt
        )
        loggedPhase = tracker.phase
        if let resumed {
            log("resumed responsibility for the recording started at \(resumed.recordingStartedAt)")
            savedRecord = nil
            persistOwnership()
        } else {
            ownedRecording.save(nil)
            savedRecord = nil
        }
    }

    static func resumableRecording(stored: OwnedRecord?, now: Date, granolaRecording: Bool) -> OwnedRecord? {
        guard
            let stored,
            granolaRecording,
            stored.recordingStartedAt <= now,
            abs(now.timeIntervalSince(stored.heartbeatAt)) < resumeWindow
        else { return nil }
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
        if let action = tracker.stopRequestedByUser() {
            log("stop requested by the user")
            logPhase(context: nil)
            perform(action)
            persistOwnership()
            return
        }
        // The notification may outlive the agent that posted it, e.g. after a restart. The user still wants it stopped.
        guard AudioSignals.isGranolaRecording(audio.snapshot()) else {
            log("stop requested, but Granola is not recording")
            return
        }
        note("stop requested for a recording the app is not tracking")
        tracker.holdOffUntilCallEnds()
        logPhase(context: nil)
        let outcome = StopSequence(routes: stopRoutes, time: time, log: log).run(recordingStartedAt: .distantPast)
        note("stop finished: \(outcome)")
        if case .failed(let reason) = outcome { presenter.present(.stopFailed(reason)) }
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
                note("Granola stopped recording after \(seconds) s on its own; if it records again during this call, the app tracks it again")
                presenter.present(.recordingStoppedByGranola)
            }
        case .recordingStartedLate:
            note("Granola started recording late; the app tracks this recording")
            if config.notifyOnStart { presenter.present(.recordingStarted) }
        }
        logPhase(context: nil)
    }

    private func start() {
        guard granola.isInstalled() else {
            note("call detected, but Granola is not installed")
            presenter.present(.granolaNotInstalled)
            tracker.startFailed(at: time.now, mayStillStart: false)
            return
        }
        log("call detected, asking Granola to start a note")
        do {
            try granola.startNewNote()
        } catch {
            note("could not open Granola: \(error)")
            presenter.present(.startFailed(.couldNotOpenGranola))
            tracker.startFailed(at: time.now, mayStillStart: false)
            return
        }
        let started = poll(timeout: Self.startWait, time: time) {
            AudioSignals.isGranolaRecording(audio.snapshot())
        }
        guard started else {
            note("Granola did not start recording within \(Int(Self.startWait)) s; a late start still counts")
            presenter.present(.startFailed(.didNotStartRecording))
            tracker.startFailed(at: time.now, mayStillStart: true)
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
        let now = time.now
        guard let startedAt = tracker.ownedRecordingStartedAt else {
            if savedRecord != nil {
                ownedRecording.save(nil)
                savedRecord = nil
            }
            return
        }
        if let saved = savedRecord,
           saved.recordingStartedAt == startedAt,
           now.timeIntervalSince(saved.heartbeatAt) < Self.heartbeatInterval {
            return
        }
        let record = OwnedRecord(recordingStartedAt: startedAt, heartbeatAt: now)
        ownedRecording.save(record)
        savedRecord = record
    }
}

/// What the running app reports about itself, for `doctor`.
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

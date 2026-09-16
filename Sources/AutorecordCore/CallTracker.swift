import Foundation

/// One look at the system, taken once a second.
public struct Observation: Equatable, Sendable {
    public var now: Date
    public var signal: CallSignal
    public var granolaRecording: Bool
    /// Whether Granola is the frontmost app. Used to guess whether a stop came from the user's own click.
    public var granolaFrontmost: Bool

    public init(now: Date, signal: CallSignal, granolaRecording: Bool, granolaFrontmost: Bool = false) {
        self.now = now
        self.signal = signal
        self.granolaRecording = granolaRecording
        self.granolaFrontmost = granolaFrontmost
    }
}

public enum TrackerAction: Equatable, Sendable {
    case startRecording
    case stopRecording(recordingStartedAt: Date)
    /// Granola stopped a recording this tracker started while the call was still going.
    case recordingStoppedExternally(recordingStartedAt: Date, likelyByUser: Bool)
}

/// Pure state machine that turns observations into start and stop actions.
///
/// It only ever stops a recording it started itself. If Granola was already recording when the call
/// began, or the recording was stopped by someone else, it stands aside until the call is over.
public struct CallTracker: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Microphone and speaker are both open; waiting out `startDelay`.
        case callStarting(since: Date)
        /// The start action is out; waiting for `startSucceeded` or `startFailed`.
        case awaitingStart
        /// Granola is recording a call this tracker started.
        case recording(startedAt: Date)
        /// The call went silent; waiting out `endGrace` before stopping.
        case callEnding(since: Date, recordingStartedAt: Date)
        /// The stop action is out; waiting for `stopFinished`. `callOver` is false when the user asked to stop mid-call.
        case awaitingStop(recordingStartedAt: Date, callOver: Bool)
        /// A call is in progress, but no recording of ours is. `quietSince` is set once the call goes silent.
        case notOurs(quietSince: Date?)
    }

    public private(set) var phase: Phase
    public let startDelay: TimeInterval
    public let endGrace: TimeInterval
    /// How long Granola must stay off the microphone before it counts as stopped.
    /// Granola briefly releases the microphone when it restarts its audio process or the input device changes.
    public let granolaStopGrace: TimeInterval

    private struct GranolaQuiet: Equatable, Sendable {
        var since: Date
        var frontmost: Bool
    }

    private var granolaQuiet: GranolaQuiet?

    public init(
        startDelay: TimeInterval,
        endGrace: TimeInterval,
        granolaStopGrace: TimeInterval = 5,
        restoredRecordingStartedAt: Date? = nil
    ) {
        self.startDelay = startDelay
        self.endGrace = endGrace
        self.granolaStopGrace = granolaStopGrace
        self.phase = restoredRecordingStartedAt.map { .recording(startedAt: $0) } ?? .idle
    }

    /// Start time of the recording this tracker is responsible for, if any.
    public var ownedRecordingStartedAt: Date? {
        switch phase {
        case .recording(let startedAt), .callEnding(_, let startedAt), .awaitingStop(let startedAt, _):
            return startedAt
        case .idle, .callStarting, .awaitingStart, .notOurs:
            return nil
        }
    }

    public mutating func step(_ observation: Observation) -> [TrackerAction] {
        // Several transitions can happen within one observation, e.g. idle -> callStarting -> start
        // when startDelay is zero. Re-evaluate until the phase settles. There is no cycle, because every
        // transition back requires the opposite observation.
        while true {
            let before = phase
            let actions = transition(observation)
            if !isWatchingGranola { granolaQuiet = nil }
            if !actions.isEmpty || phase == before { return actions }
        }
    }

    public mutating func startSucceeded(at date: Date) {
        guard phase == .awaitingStart else { return }
        phase = .recording(startedAt: date)
    }

    /// Granola did not start recording. Stay out of the way until this call is over.
    public mutating func startFailed() {
        guard phase == .awaitingStart else { return }
        phase = .notOurs(quietSince: nil)
    }

    /// The user asked to stop, e.g. from the notification. Returns the action to run, if there is anything to stop.
    public mutating func stopRequestedByUser() -> TrackerAction? {
        switch phase {
        case .recording(let startedAt), .callEnding(_, let startedAt):
            phase = .awaitingStop(recordingStartedAt: startedAt, callOver: false)
            granolaQuiet = nil
            return .stopRecording(recordingStartedAt: startedAt)
        case .idle, .callStarting, .awaitingStart, .awaitingStop, .notOurs:
            return nil
        }
    }

    /// Called after a stop attempt, successful or not.
    public mutating func stopFinished() {
        guard case .awaitingStop(_, let callOver) = phase else { return }
        phase = callOver ? .idle : .notOurs(quietSince: nil)
    }

    private var isWatchingGranola: Bool {
        switch phase {
        case .recording, .callEnding: return true
        case .idle, .callStarting, .awaitingStart, .awaitingStop, .notOurs: return false
        }
    }

    private mutating func transition(_ observation: Observation) -> [TrackerAction] {
        let now = observation.now
        let signal = observation.signal

        switch phase {
        case .idle:
            if signal == .full { phase = .callStarting(since: now) }
            return []

        case .callStarting(let since):
            guard signal == .full else {
                phase = .idle
                return []
            }
            guard now.timeIntervalSince(since) >= startDelay else { return [] }
            if observation.granolaRecording {
                phase = .notOurs(quietSince: nil)
                return []
            }
            phase = .awaitingStart
            return [.startRecording]

        case .awaitingStart, .awaitingStop:
            return []

        case .recording(let startedAt):
            if let likelyByUser = confirmGranolaStopped(observation) {
                phase = .notOurs(quietSince: nil)
                return [.recordingStoppedExternally(recordingStartedAt: startedAt, likelyByUser: likelyByUser)]
            }
            if signal == .none { phase = .callEnding(since: now, recordingStartedAt: startedAt) }
            return []

        case .callEnding(let since, let startedAt):
            if confirmGranolaStopped(observation) != nil {
                // Stopped while the call was winding down: nothing left to do and nothing worth reporting.
                phase = .notOurs(quietSince: since)
                return []
            }
            if signal != .none {
                phase = .recording(startedAt: startedAt)
                return []
            }
            guard now.timeIntervalSince(since) >= endGrace else { return [] }
            phase = .awaitingStop(recordingStartedAt: startedAt, callOver: true)
            return [.stopRecording(recordingStartedAt: startedAt)]

        case .notOurs(let quietSince):
            if signal != .none {
                if quietSince != nil { phase = .notOurs(quietSince: nil) }
                return []
            }
            guard let quietSince else {
                phase = .notOurs(quietSince: now)
                return []
            }
            if now.timeIntervalSince(quietSince) >= endGrace { phase = .idle }
            return []
        }
    }

    /// Returns nil while Granola records, or while it has been off the microphone for less than `granolaStopGrace`.
    /// Otherwise returns whether Granola was frontmost when it went quiet.
    private mutating func confirmGranolaStopped(_ observation: Observation) -> Bool? {
        if observation.granolaRecording {
            granolaQuiet = nil
            return nil
        }
        let quiet = granolaQuiet ?? GranolaQuiet(since: observation.now, frontmost: observation.granolaFrontmost)
        granolaQuiet = quiet
        guard observation.now.timeIntervalSince(quiet.since) >= granolaStopGrace else { return nil }
        return quiet.frontmost
    }
}

extension CallTracker.Phase: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .callStarting: return "call-starting"
        case .awaitingStart: return "starting-granola"
        case .recording: return "recording"
        case .callEnding: return "call-ending"
        case .awaitingStop: return "stopping-granola"
        case .notOurs(let quietSince): return quietSince == nil ? "not-ours" : "not-ours-quiet"
        }
    }
}

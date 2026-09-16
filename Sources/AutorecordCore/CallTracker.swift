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
    /// A start that had timed out went through after all. The recording is tracked from now on.
    case recordingStartedLate
}

/// Pure state machine that turns observations into start and stop actions.
///
/// It only ever stops a recording it started itself. If Granola was already recording when the call
/// began, or the user stopped the recording, it stands aside until the call is over.
public struct CallTracker: Sendable {
    /// A recording that is not running now but belongs to this tracker if Granola records again during the call.
    public enum Claim: Equatable, Sendable {
        /// Granola stopped our recording without the user, e.g. to ask for consent.
        case lostRecording(startedAt: Date)
        /// Granola did not start in time, but the deep link may still take effect.
        case pendingStart(since: Date)
    }

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
        /// A call is in progress, but no recording of ours is running. `quietSince` is set once the call goes silent.
        case notOurs(quietSince: Date?, claim: Claim?)
    }

    public private(set) var phase: Phase
    public let startDelay: TimeInterval
    public let endGrace: TimeInterval
    /// How long Granola must stay off the microphone before it counts as stopped mid-call.
    /// Granola briefly releases the microphone when its audio process restarts or a headset switches profile.
    public let granolaStopGrace: TimeInterval
    /// How long after a timed-out start a recording that Granola starts late still counts as ours.
    public let lateStartWindow: TimeInterval

    private struct GranolaQuiet: Equatable, Sendable {
        var since: Date
        var frontmost: Bool
    }

    private var granolaQuiet: GranolaQuiet?

    public init(
        startDelay: TimeInterval,
        endGrace: TimeInterval,
        granolaStopGrace: TimeInterval = 15,
        lateStartWindow: TimeInterval = 180,
        restoredRecordingStartedAt: Date? = nil
    ) {
        self.startDelay = startDelay
        self.endGrace = endGrace
        self.granolaStopGrace = granolaStopGrace
        self.lateStartWindow = lateStartWindow
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

    /// Granola did not start recording. With `mayStillStart`, a recording Granola starts later in this call is claimed.
    public mutating func startFailed(at date: Date, mayStillStart: Bool) {
        guard phase == .awaitingStart else { return }
        phase = .notOurs(quietSince: nil, claim: mayStillStart ? .pendingStart(since: date) : nil)
    }

    /// The user asked to stop, e.g. from the notification. Returns the action to run, if the tracker owns a recording.
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

    /// The user stopped a recording this tracker does not own. Start nothing, and claim nothing, until the call ends.
    public mutating func holdOffUntilCallEnds() {
        switch phase {
        case .idle, .callStarting:
            phase = .notOurs(quietSince: nil, claim: nil)
        case .notOurs(let quietSince, _):
            phase = .notOurs(quietSince: quietSince, claim: nil)
        case .awaitingStart, .recording, .callEnding, .awaitingStop:
            break
        }
    }

    /// Called after a stop attempt, successful or not.
    public mutating func stopFinished() {
        guard case .awaitingStop(_, let callOver) = phase else { return }
        phase = callOver ? .idle : .notOurs(quietSince: nil, claim: nil)
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
                phase = .notOurs(quietSince: nil, claim: nil)
                return []
            }
            phase = .awaitingStart
            return [.startRecording]

        case .awaitingStart, .awaitingStop:
            return []

        case .recording(let startedAt):
            if let likelyByUser = confirmGranolaStopped(observation) {
                phase = .notOurs(quietSince: nil, claim: likelyByUser ? nil : .lostRecording(startedAt: startedAt))
                return [.recordingStoppedExternally(recordingStartedAt: startedAt, likelyByUser: likelyByUser)]
            }
            if signal == .none { phase = .callEnding(since: now, recordingStartedAt: startedAt) }
            return []

        case .callEnding(let since, let startedAt):
            // Granola releasing the microphone now changes nothing: the stop sequence
            // copes with a recording that has already ended.
            if signal != .none {
                phase = .recording(startedAt: startedAt)
                return []
            }
            guard now.timeIntervalSince(since) >= endGrace else { return [] }
            phase = .awaitingStop(recordingStartedAt: startedAt, callOver: true)
            return [.stopRecording(recordingStartedAt: startedAt)]

        case .notOurs(let quietSince, let claim):
            if let claim, observation.granolaRecording {
                switch claim {
                case .lostRecording(let startedAt):
                    phase = .recording(startedAt: startedAt)
                    return []
                case .pendingStart:
                    phase = .recording(startedAt: now)
                    return [.recordingStartedLate]
                }
            }
            if case .pendingStart(let since)? = claim, now.timeIntervalSince(since) >= lateStartWindow {
                phase = .notOurs(quietSince: quietSince, claim: nil)
                return []
            }
            if signal != .none {
                if quietSince != nil { phase = .notOurs(quietSince: nil, claim: claim) }
                return []
            }
            guard let quietSince else {
                phase = .notOurs(quietSince: now, claim: claim)
                return []
            }
            // A pending start keeps the phase alive until its window closes, even after the call.
            if case .pendingStart? = claim { return [] }
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
        case .notOurs(let quietSince, let claim):
            let base = quietSince == nil ? "not-ours" : "not-ours-quiet"
            switch claim {
            case nil: return base
            case .lostRecording?: return base + "-reclaimable"
            case .pendingStart?: return base + "-late-start"
            }
        }
    }
}

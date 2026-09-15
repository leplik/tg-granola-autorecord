import Foundation

public enum TrackerCommand: Equatable, Sendable {
    case startRecording
    case stopRecording(recordingStartedAt: Date)
}

/// Pure state machine that turns once-a-second audio observations into start and stop commands.
///
/// It only ever stops a recording it started itself. If Granola was already recording when the call
/// began, or the user stopped the recording by hand, it stands aside until the call is over.
public struct CallTracker: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Microphone and speaker are both open; waiting out `startDelay`.
        case callStarting(since: Date)
        /// The start command is out; waiting for the runner to report the result.
        case awaitingStart
        /// Granola is recording a call this tracker started.
        case recording(startedAt: Date)
        /// The call went silent; waiting out `endGrace` before stopping.
        case callEnding(since: Date, recordingStartedAt: Date)
        /// The stop command is out; waiting for the runner to report back.
        case awaitingStop
        /// A call is in progress, but the recording is not ours to manage.
        /// `quietSince` is set once the call has gone silent.
        case notOurs(quietSince: Date?)
    }

    public private(set) var phase: Phase = .idle
    public let startDelay: TimeInterval
    public let endGrace: TimeInterval

    public init(startDelay: TimeInterval, endGrace: TimeInterval) {
        self.startDelay = startDelay
        self.endGrace = endGrace
    }

    public mutating func step(now: Date, signal: CallSignal, granolaRecording: Bool) -> TrackerCommand? {
        // Several transitions can happen within one observation, e.g. idle -> callStarting -> start
        // when startDelay is zero. Re-evaluate until the phase settles. No cycle exists because every
        // transition back requires the opposite signal.
        while true {
            let before = phase
            if let command = transition(now: now, signal: signal, granolaRecording: granolaRecording) {
                return command
            }
            if phase == before { return nil }
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

    /// Called after a stop attempt, successful or not. The call is already over at this point.
    public mutating func stopFinished() {
        guard phase == .awaitingStop else { return }
        phase = .idle
    }

    private mutating func transition(now: Date, signal: CallSignal, granolaRecording: Bool) -> TrackerCommand? {
        switch phase {
        case .idle:
            if signal == .full { phase = .callStarting(since: now) }
            return nil

        case .callStarting(let since):
            guard signal == .full else {
                phase = .idle
                return nil
            }
            guard now.timeIntervalSince(since) >= startDelay else { return nil }
            if granolaRecording {
                phase = .notOurs(quietSince: nil)
                return nil
            }
            phase = .awaitingStart
            return .startRecording

        case .awaitingStart, .awaitingStop:
            return nil

        case .recording(let startedAt):
            if !granolaRecording {
                // Stopped by the user or by Granola itself. Don't fight it.
                phase = .notOurs(quietSince: nil)
            } else if signal == .none {
                phase = .callEnding(since: now, recordingStartedAt: startedAt)
            }
            return nil

        case .callEnding(let since, let startedAt):
            if !granolaRecording {
                phase = .notOurs(quietSince: since)
                return nil
            }
            if signal != .none {
                phase = .recording(startedAt: startedAt)
                return nil
            }
            guard now.timeIntervalSince(since) >= endGrace else { return nil }
            phase = .awaitingStop
            return .stopRecording(recordingStartedAt: startedAt)

        case .notOurs(let quietSince):
            if signal != .none {
                if quietSince != nil { phase = .notOurs(quietSince: nil) }
                return nil
            }
            guard let quietSince else {
                phase = .notOurs(quietSince: now)
                return nil
            }
            if now.timeIntervalSince(quietSince) >= endGrace { phase = .idle }
            return nil
        }
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

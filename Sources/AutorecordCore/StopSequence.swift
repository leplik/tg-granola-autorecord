import Foundation

public enum ButtonPressResult: Equatable, Sendable {
    case pressed
    case notTrusted
    case granolaNotRunning
    case notFound(buttonsSeen: Int)
    case failed(code: Int32)
}

extension ButtonPressResult: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pressed: return "pressed the stop button"
        case .notTrusted: return "no Accessibility permission"
        case .granolaNotRunning: return "Granola is not running"
        case .notFound(let seen): return "no unambiguous stop button among \(seen) buttons"
        case .failed(let code): return "pressing failed with AXError \(code)"
        }
    }
}

public enum StopOutcome: Equatable, Sendable {
    case alreadyStopped
    case stoppedViaSocket
    case stoppedViaButton
    /// Granola is still recording. Carries what the button route ran into; `.pressed` means the press had no effect.
    case failed(ButtonPressResult)
}

extension StopOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyStopped: return "Granola had already stopped"
        case .stoppedViaSocket: return "stopped via the Meet extension socket"
        case .stoppedViaButton: return "stopped by pressing the stop button"
        case .failed(let reason): return "Granola is still recording (\(reason))"
        }
    }
}

/// The side effects the stop sequence needs. Implemented against the real Granola app in the executable.
public protocol StopRoutes {
    func isGranolaRecording() -> Bool
    func isExtensionAutoStopEnabled() -> Bool
    func sendMeetingEnded() throws
    func pressStopButton() -> ButtonPressResult
}

/// Stops Granola's recording. Granola has no public stop API, so this tries two unofficial routes in order.
public struct StopSequence {
    public static let socketWait: TimeInterval = 30
    public static let buttonWait: TimeInterval = 10

    private let routes: StopRoutes
    private let time: TimeSource
    private let log: (String) -> Void

    public init(routes: StopRoutes, time: TimeSource, log: @escaping (String) -> Void) {
        self.routes = routes
        self.time = time
        self.log = log
    }

    public func run(recordingStartedAt: Date) -> StopOutcome {
        guard routes.isGranolaRecording() else { return .alreadyStopped }
        if stopViaSocket(recordingStartedAt: recordingStartedAt) { return .stoppedViaSocket }

        let result = routes.pressStopButton()
        log("button route: \(result)")
        guard result == .pressed else {
            // Someone may have stopped the recording while the routes were being tried.
            return routes.isGranolaRecording() ? .failed(result) : .alreadyStopped
        }
        if poll(timeout: Self.buttonWait, time: time, until: { !routes.isGranolaRecording() }) {
            return .stoppedViaButton
        }
        log("pressed the stop button, but Granola kept recording")
        return .failed(.pressed)
    }

    /// Route 1: report `meeting-ended` the way Granola's Google Meet extension does.
    /// Granola acts on it only with its `meet_consent_extension_auto_stop` flag on
    /// and a recording that is at least three minutes old.
    private func stopViaSocket(recordingStartedAt: Date) -> Bool {
        guard routes.isExtensionAutoStopEnabled() else {
            log("socket route skipped: Granola flag \(Granola.extensionAutoStopFlag) is off")
            return false
        }
        let age = time.now.timeIntervalSince(recordingStartedAt)
        guard age >= Granola.extensionAutoStopMinimumRecording else {
            log("socket route skipped: the recording is \(Int(age)) s old, Granola ignores meeting-ended before \(Int(Granola.extensionAutoStopMinimumRecording)) s")
            return false
        }
        do {
            try routes.sendMeetingEnded()
        } catch {
            log("socket route failed: \(error)")
            return false
        }
        log("sent meeting-ended, waiting up to \(Int(Self.socketWait)) s")
        if poll(timeout: Self.socketWait, time: time, until: { !routes.isGranolaRecording() }) { return true }
        log("Granola kept recording after meeting-ended")
        return false
    }
}

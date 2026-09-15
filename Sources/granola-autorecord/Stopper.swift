import AutorecordCore
import Foundation

enum StopOutcome: String {
    case alreadyStopped = "Granola had already stopped"
    case socket = "stopped via the Meet extension socket"
    case accessibility = "stopped by pressing the stop button"
    case manual = "could not stop; the user was notified"
}

/// Stops Granola's recording. Granola has no public stop API, so this tries two unofficial routes in order
/// and asks the user to stop by hand when both fail.
struct Stopper {
    let granola: GranolaApp
    let isRecording: () -> Bool

    static let socketWait: TimeInterval = 30
    static let buttonWait: TimeInterval = 10

    func stop(recordingStartedAt: Date) -> StopOutcome {
        guard isRecording() else { return .alreadyStopped }
        if stopViaSocket(recordingStartedAt: recordingStartedAt) { return .socket }
        if stopViaButton() { return .accessibility }
        Notifier.notify("The call is over, but Granola is still recording. Please stop it by hand.")
        return .manual
    }

    /// Route 1: pretend to be the Meet extension and report that the meeting ended.
    /// Granola only acts on it when its `meet_consent_extension_auto_stop` flag is on
    /// and the recording is at least three minutes old.
    private func stopViaSocket(recordingStartedAt: Date) -> Bool {
        guard granola.isExtensionAutoStopEnabled() else {
            Log.info("socket route skipped: Granola flag \(Granola.extensionAutoStopFlag) is off")
            return false
        }
        let age = Date().timeIntervalSince(recordingStartedAt)
        guard age >= Granola.extensionAutoStopMinimumRecording else {
            Log.info("socket route skipped: recording is \(Int(age)) s old, Granola ignores meeting-ended before \(Int(Granola.extensionAutoStopMinimumRecording)) s")
            return false
        }
        do {
            try granola.sendMeetingEnded()
        } catch {
            Log.warn("socket route failed: \(error)")
            return false
        }
        Log.info("sent meeting-ended; waiting up to \(Int(Self.socketWait)) s for Granola to stop")
        if waitUntil(timeout: Self.socketWait, { !isRecording() }) { return true }
        Log.warn("Granola kept recording after meeting-ended")
        return false
    }

    /// Route 2: press Granola's stop button through the Accessibility API.
    private func stopViaButton() -> Bool {
        let result = GranolaAccessibility.pressStopButton(bringToFront: granola.bringToFront)
        Log.info("button route: \(result)")
        guard case .pressed = result else { return false }
        if waitUntil(timeout: Self.buttonWait, { !isRecording() }) { return true }
        Log.warn("pressed the stop button, but Granola kept recording")
        return false
    }
}

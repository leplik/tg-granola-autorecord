import AppKit
import AutorecordCore
import UserNotifications

/// Native notifications with action buttons. Must live in the app bundle's process.
final class Notifications: NSObject, NoticePresenter, UNUserNotificationCenterDelegate {
    enum Action: String {
        case stopRecording = "STOP_RECORDING"
        case openGranola = "OPEN_GRANOLA"
        case openAccessibilitySettings = "OPEN_ACCESSIBILITY_SETTINGS"
    }

    private enum Category: String {
        case recording = "RECORDING"
        case needsGranola = "NEEDS_GRANOLA"
        case needsAccessibility = "NEEDS_ACCESSIBILITY"
        case info = "INFO"
    }

    static let recordingNotificationID = "recording"

    private let center = UNUserNotificationCenter.current()
    private let onAction: (Action) -> Void

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init()
    }

    func activate() {
        center.delegate = self
        let stop = UNNotificationAction(identifier: Action.stopRecording.rawValue, title: "Stop Recording", options: [])
        let openGranola = UNNotificationAction(identifier: Action.openGranola.rawValue, title: "Open Granola", options: [.foreground])
        let openSettings = UNNotificationAction(identifier: Action.openAccessibilitySettings.rawValue, title: "Open Settings", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.recording.rawValue, actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.needsGranola.rawValue, actions: [openGranola], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.needsAccessibility.rawValue, actions: [openSettings, openGranola], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.info.rawValue, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.warn("notification permission request failed: \(error.localizedDescription)")
            } else if !granted {
                Log.warn("notifications are turned off for \(Product.name)")
            }
        }
    }

    /// Whether notifications may be shown. Calls back on an arbitrary queue.
    func checkAllowed(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
        }
    }

    // MARK: NoticePresenter

    func present(_ notice: AgentNotice) {
        let content = Self.content(for: notice)
        post(id: content.id, title: content.title, body: content.body, category: content.category)
    }

    func post(id: String, title: String, body: String, category: String = Category.info.rawValue) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = category == Category.recording.rawValue ? nil : .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.warn("could not show notification: \(error.localizedDescription)") }
        }
    }

    func removeRecordingNotification() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.recordingNotificationID])
    }

    private static func content(for notice: AgentNotice) -> (id: String, title: String, body: String, category: String) {
        switch notice {
        case .recordingStarted:
            return (recordingNotificationID, "Recording Telegram call",
                    "Granola is taking notes and stops when the call ends.", Category.recording.rawValue)
        case .granolaNotInstalled:
            return ("start-failed", "Granola is not installed",
                    "Install the Granola app to record Telegram calls.", Category.info.rawValue)
        case .startFailed(.couldNotOpenGranola):
            return ("start-failed", "Could not start recording",
                    "Granola did not open. Start the recording in Granola.", Category.needsGranola.rawValue)
        case .startFailed(.didNotStartRecording):
            return ("start-failed", "Could not start recording",
                    "Granola did not start recording. Make sure you are signed in, or start it in Granola.", Category.needsGranola.rawValue)
        case .stopFailed(.notTrusted):
            return ("stop-failed", "Granola is still recording",
                    "Allow Accessibility access so recordings stop when calls end. Stop this one in Granola.", Category.needsAccessibility.rawValue)
        case .stopFailed(.notFound):
            return ("stop-failed", "Granola is still recording",
                    "Could not find Granola's stop button, possibly after a Granola update. Stop the recording in Granola.", Category.needsGranola.rawValue)
        case .stopFailed:
            return ("stop-failed", "Granola is still recording",
                    "The call ended, but the recording could not be stopped. Stop it in Granola.", Category.needsGranola.rawValue)
        case .recordingStoppedByGranola:
            return ("stopped-by-granola", "Granola stopped recording",
                    "The Telegram call is still going. If your workspace requires consent to record, confirm it in Granola.", Category.needsGranola.rawValue)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let action = Action(rawValue: response.actionIdentifier) {
            onAction(action)
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  response.notification.request.content.categoryIdentifier != Category.info.rawValue {
            onAction(.openGranola)
        }
        completionHandler()
    }
}

enum SystemSettings {
    static func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

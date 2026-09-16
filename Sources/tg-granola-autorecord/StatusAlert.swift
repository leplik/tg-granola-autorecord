import AppKit
import AutorecordCore
import ServiceManagement
import UserNotifications

/// What the setup is missing, shown when the app is opened.
struct SetupReport {
    var loginItem: SMAppService.Status
    var registrationError: Error?
    var accessibility: Bool
    var notifications: Bool?
    var granolaInstalled: Bool

    var hasProblems: Bool {
        loginItem != .enabled || registrationError != nil || !accessibility || notifications != true || !granolaInstalled
    }

    static func current(registrationError: Error? = nil) -> SetupReport {
        SetupReport(
            loginItem: LoginItem.service.status,
            registrationError: registrationError,
            accessibility: GranolaAccessibility.isTrusted(prompt: false),
            notifications: notificationsAllowed(),
            granolaInstalled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: Granola.bundleID) != nil
        )
    }

    private static func notificationsAllowed() -> Bool? {
        let semaphore = DispatchSemaphore(value: 0)
        var allowed: Bool?
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: allowed = true
            case .denied: allowed = false
            default: allowed = nil
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        return allowed
    }
}

enum StatusAlert {
    enum Choice {
        case keepRunning
        case turnOff
    }

    static func show(_ report: SetupReport) -> Choice {
        var lines = [
            mark(report.loginItem == .enabled, "Starts at login", missing: "Login item: \(LoginItem.describe(report.loginItem))"),
            mark(report.accessibility, "Accessibility access, to stop recordings when calls end",
                 missing: "Accessibility access is off, so recordings will not stop by themselves"),
            mark(report.notifications == true, "Notifications", missing: "Notifications are off, so there is no Stop button and no warnings"),
            mark(report.granolaInstalled, "Granola is installed", missing: "Granola is not installed"),
        ]
        if let error = report.registrationError {
            lines.append("✗ Could not add the login item: \(error.localizedDescription)")
        }

        let alert = NSAlert()
        alert.messageText = report.hasProblems ? "\(Product.name) needs attention" : "\(Product.name) is on"
        alert.informativeText = """
        When a Telegram call starts, Granola starts recording. When the call ends, the recording stops. \
        The app runs in the background and has no window.

        \(lines.joined(separator: "\n"))
        """

        var actions: [() -> Choice] = []
        if !report.accessibility {
            alert.addButton(withTitle: "Open Accessibility Settings")
            actions.append { SystemSettings.openAccessibility(); return .keepRunning }
        } else if report.notifications != true {
            alert.addButton(withTitle: "Open Notification Settings")
            actions.append { SystemSettings.openNotifications(); return .keepRunning }
        } else if report.loginItem == .requiresApproval {
            alert.addButton(withTitle: "Open Login Items")
            actions.append { SMAppService.openSystemSettingsLoginItems(); return .keepRunning }
        }
        alert.addButton(withTitle: "Done")
        actions.append { .keepRunning }
        alert.addButton(withTitle: "Turn Off")
        actions.append { .turnOff }

        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return actions.indices.contains(index) ? actions[index]() : .keepRunning
    }

    /// Asked when the app is opened after the user turned it off. Returns true to turn it back on.
    static func offerToTurnOn() -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(Product.name) is off"
        alert.informativeText = "Turn it on to record Telegram calls in Granola automatically."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func mark(_ ok: Bool, _ text: String, missing: String) -> String {
        ok ? "✓ \(text)" : "✗ \(missing)"
    }

    /// Also rejects App Translocation, where macOS runs a downloaded app from a random read-only path.
    static func isInApplicationsFolder() -> Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    static func askToMoveToApplications() {
        let alert = NSAlert()
        alert.messageText = "Move \(Product.name) to Applications"
        alert.informativeText = """
        The app starts at login from wherever it is, so it has to stay in the Applications folder. \
        Move it there, then open it again.

        Now running from: \(Bundle.main.bundlePath)
        """
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

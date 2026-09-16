import AppKit
import AutorecordCore
import ServiceManagement
import UserNotifications

/// What the user sees when opening the app from Finder: it turns the agent on and shows what is still missing.
enum Setup {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var problems: [String] = []
        let service = LoginItem.service
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                problems.append("The background agent could not be turned on: \(error.localizedDescription)")
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let status = service.status
        let trusted = GranolaAccessibility.isTrusted(prompt: false)
        let granolaInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Granola.bundleID) != nil

        var lines = [
            check(status == .enabled, "Runs in the background and at login", missing: "Background agent: \(LoginItem.describe(status))"),
            check(trusted, "Accessibility access, to stop recordings when calls end", missing: "Accessibility access is off, so recordings will not stop by themselves"),
            check(granolaInstalled, "Granola is installed", missing: "Granola is not installed"),
        ]
        lines.append(contentsOf: problems.map { "✗ \($0)" })

        let alert = NSAlert()
        alert.messageText = status == .enabled ? "\(Product.name) is on" : "\(Product.name) needs attention"
        alert.informativeText = """
        When a Telegram call starts, Granola starts recording. When the call ends, the recording stops.

        \(lines.joined(separator: "\n"))
        """
        var buttons: [() -> Void] = []
        if !trusted {
            alert.addButton(withTitle: "Open Accessibility Settings")
            buttons.append { SystemSettings.openAccessibility() }
        } else if status == .requiresApproval {
            alert.addButton(withTitle: "Open Login Items")
            buttons.append { SMAppService.openSystemSettingsLoginItems() }
        }
        alert.addButton(withTitle: "Done")
        buttons.append {}
        alert.addButton(withTitle: "Turn Off")
        buttons.append {
            do {
                try service.unregister()
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }

        app.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if buttons.indices.contains(index) { buttons[index]() }
        exit(0)
    }

    private static func check(_ ok: Bool, _ text: String, missing: String) -> String {
        ok ? "✓ \(text)" : "✗ \(missing)"
    }
}

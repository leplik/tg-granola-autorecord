import AppKit
import AutorecordCore
import Foundation

/// `doctor`: one report that answers most support questions.
enum Doctor {
    private enum Mark: String {
        case ok = "✓"
        case problem = "✗"
        case warning = "!"
        case info = "•"
    }

    static func run(paths: Paths) -> Int32 {
        var problems = 0
        func line(_ mark: Mark, _ text: String) {
            if mark == .problem { problems += 1 }
            print("  \(mark.rawValue) \(text)")
        }
        func section(_ title: String) {
            print("\n\(title)")
        }

        print("\(Product.name) \(Product.version)")

        section("System")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)) {
            line(.ok, osText)
        } else {
            line(.problem, "\(osText): 14.4 or later is required to see which apps use the microphone")
        }

        section("App")
        line(.info, "this command runs from \(Bundle.main.bundlePath)")
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Product.bundleID) {
            line(.ok, "installed at \(appURL.path)")
        } else {
            line(.problem, "the app is not installed")
        }
        if Preferences.turnedOffByUser {
            line(.problem, "turned off: run `\(Product.command) enable` or open the app")
        }
        let loginItem = LoginItem.service.status
        line(loginItem == .enabled ? .ok : .problem, LoginItem.describe(loginItem))
        reportAgentStatus(paths: paths, line: line)

        section("Granola")
        if let version = GranolaApp.installedVersion() {
            if compareVersions(version, Granola.testedVersion) == .orderedDescending {
                line(.warning, "version \(version) is newer than the tested \(Granola.testedVersion); if stopping fails, see the README")
            } else {
                line(.ok, "version \(version)")
            }
        } else {
            line(.problem, "Granola is not installed")
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Granola.bundleID).isEmpty {
            line(.info, "not running; it opens by itself when a call starts")
        } else {
            line(.ok, "running")
        }
        let granola = GranolaApp(config: .default, homeDirectory: paths.homeDirectory)
        line(.info, "stop via Meet extension socket: \(granola.isExtensionAutoStopEnabled() ? "allowed by Granola" : "not allowed by Granola, the stop button is used")")

        section("Telegram")
        let config = (try? ConfigLoader.load(from: paths.config)) ?? .default
        var anyTelegram = false
        for bundleID in config.apps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                anyTelegram = true
                let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                line(.ok, "\(url.lastPathComponent) \(version) (\(bundleID))")
            }
        }
        if !anyTelegram { line(.problem, "no Telegram client found among \(config.apps.joined(separator: ", "))") }

        section("Settings")
        if FileManager.default.fileExists(atPath: paths.config.path) {
            do {
                _ = try ConfigLoader.load(from: paths.config)
                line(.ok, "\(paths.config.path) is valid")
            } catch {
                line(.problem, "\(paths.config.path): \(error)")
            }
        } else {
            line(.info, "no settings file, using the defaults")
        }

        section("Log")
        line(.info, paths.log.path)
        for logLine in lastLines(of: paths.log, count: 8) {
            print("      \(logLine)")
        }

        print("")
        print(problems == 0 ? "No problems found." : "\(problems) problem\(problems == 1 ? "" : "s") found.")
        return problems == 0 ? 0 : 1
    }

    private static func reportAgentStatus(paths: Paths, line: (Mark, String) -> Void) {
        guard
            let data = try? Data(contentsOf: paths.status),
            let status = try? AgentStatus.decoder().decode(AgentStatus.self, from: data)
        else {
            line(.problem, "the app has never run: open it once")
            return
        }
        let age = Int(Date().timeIntervalSince(status.updatedAt))
        if isOurApp(pid: status.pid) {
            // Starting or stopping a recording can keep the app busy for up to a minute between status updates.
            line(.ok, "running as pid \(status.pid), state \(status.phase)" + (age > 90 ? ", busy for \(age) s" : ""))
        } else {
            line(.problem, "not running, last seen \(age) s ago: open the app or run `\(Product.command) enable`")
        }
        if status.version != Product.version {
            line(.warning, "the running app is version \(status.version), this command is \(Product.version): run `\(Product.command) restart`")
        }
        line(status.accessibilityTrusted ? .ok : .problem,
             status.accessibilityTrusted ? "Accessibility access allowed" : "Accessibility access is off: recordings will not stop by themselves")
        switch status.notificationsAllowed {
        case true?: line(.ok, "notifications allowed")
        case false?: line(.problem, "notifications are off: allow them in System Settings > Notifications > \(Product.name)")
        case nil: line(.info, "notification permission not checked yet")
        }
        if let lastEvent = status.lastEvent {
            line(.info, "last event: \(lastEvent)")
        }
    }

    /// The process ID could have been reused, so also check which executable it runs.
    private static func isOurApp(pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/Contents/MacOS/\(Product.command)")
    }

    private static func lastLines(of url: URL, count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(count)).map(String.init)
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

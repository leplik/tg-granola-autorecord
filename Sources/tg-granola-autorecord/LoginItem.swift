import AppKit
import AutorecordCore
import Foundation
import ServiceManagement

/// The app registers itself as a login item. LaunchServices starts it at login, which keeps notifications working:
/// the User Notifications framework does not work from a plain launchd agent.
enum LoginItem {
    static var service: SMAppService { .mainApp }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "starts at login"
        case .requiresApproval: return "waiting for approval in System Settings > General > Login Items"
        case .notRegistered: return "does not start at login"
        case .notFound: return "not registered yet"
        @unknown default: return "unknown login item state (\(status.rawValue))"
        }
    }

    /// Registers unless already registered or waiting for the user's approval. Returns the error, if any.
    @discardableResult
    static func ensureRegistered() -> Error? {
        switch service.status {
        case .enabled, .requiresApproval:
            return nil
        default:
            do {
                try service.register()
                return nil
            } catch {
                return error
            }
        }
    }
}

/// Settings the app keeps for itself in its defaults domain.
enum Preferences {
    private static let defaults = UserDefaults.standard

    /// Set when the user turns the app off, so that it does not turn itself back on.
    static var turnedOffByUser: Bool {
        get { defaults.bool(forKey: "turnedOffByUser") }
        set { defaults.set(newValue, forKey: "turnedOffByUser") }
    }

    static var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: "hasCompletedFirstRun") }
        set { defaults.set(newValue, forKey: "hasCompletedFirstRun") }
    }
}

/// Finds and controls the running copy of the app from the command line.
enum RunningApp {
    /// Process IDs of running copies of the app, not counting this process.
    static func pids() -> [pid_t] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Product.bundleID)
            .map(\.processIdentifier)
            .filter { $0 != own }
    }

    /// Stops running copies with SIGTERM and waits up to five seconds for them to exit.
    static func stop() {
        let running = pids()
        running.forEach { kill($0, SIGTERM) }
        _ = poll(timeout: 5, interval: 0.2, time: SystemTime()) {
            running.allSatisfy { kill($0, 0) != 0 }
        }
    }

    /// Starts the installed app in the background. Launching by path rather than bundle identifier
    /// avoids picking up a stray copy, e.g. a build folder or an unzipped download.
    static func launch() throws {
        let path = StatusAlert.isInApplicationsFolder() ? Bundle.main.bundlePath : "/Applications/\(Product.name).app"
        try Shell.run("/usr/bin/open", ["-g", "-a", path])
    }
}

/// An exclusive lock held for the lifetime of the running app.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    /// Returns false when another copy of the app already holds the lock.
    static func acquire(at url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }
}

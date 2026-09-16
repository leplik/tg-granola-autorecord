import AutorecordCore
import Foundation
import ServiceManagement

/// The background agent, registered with launchd through ServiceManagement.
/// Its plist ships inside the app bundle at Contents/Library/LaunchAgents.
enum LoginItem {
    static let plistName = "\(Product.bundleID).agent.plist"
    static let label = "\(Product.bundleID).agent"

    static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval in System Settings > General > Login Items"
        case .notRegistered: return "turned off"
        case .notFound: return "not found in the app bundle"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    /// Whether launchd currently has the agent loaded, checked without relying on this process's bundle.
    static func isLoaded() -> Bool {
        (try? Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])) != nil
    }

    static func restart() throws {
        try Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }
}

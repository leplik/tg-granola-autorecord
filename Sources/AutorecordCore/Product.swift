import Foundation

public enum Product {
    public static let name = "Telegram-Granola Autorecord"
    public static let bundleID = "pro.saac.tg-granola-autorecord"
    public static let command = "tg-granola-autorecord"
    /// Single source of truth for the version. `scripts/build-app.sh` copies it into Info.plist.
    public static let version = "1.0.0"
    public static let repository = "https://github.com/leplik/tg-granola-autorecord"
}

/// Where the agent keeps its files.
public struct Paths: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory
    }

    public var config: URL {
        homeDirectory.appendingPathComponent(".config/\(Product.command)/config.json")
    }

    public var supportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/\(Product.command)", isDirectory: true)
    }

    /// Written by the running agent so that `doctor` can report on it.
    public var status: URL {
        supportDirectory.appendingPathComponent("status.json")
    }

    /// Remembers a recording the agent started, so a restarted agent can still stop it.
    public var ownedRecording: URL {
        supportDirectory.appendingPathComponent("owned-recording.json")
    }

    public var log: URL {
        homeDirectory.appendingPathComponent("Library/Logs/\(Product.command).log")
    }
}

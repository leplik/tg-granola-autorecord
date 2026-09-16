import Foundation

/// User settings. Every field is optional in the JSON file; missing fields fall back to `Config.default`.
public struct Config: Equatable, Sendable {
    /// Bundle identifiers of the Telegram clients to watch.
    public var apps: [String]
    /// How long Telegram must hold both the microphone and the speaker before recording starts.
    public var startDelaySeconds: Double
    /// How long Telegram must stay silent before the call counts as over.
    /// Rides out reconnects and audio device switches without splitting the note.
    public var endGraceSeconds: Double
    /// Value passed to Granola as `creation_source` when a note is created.
    public var creationSource: String
    /// Show a notification with a Stop button when a recording starts.
    public var notifyOnStart: Bool

    public static let defaultApps = [
        "com.tdesktop.Telegram", // Telegram Desktop from telegram.org
        "org.telegram.desktop", // Telegram Desktop from the Mac App Store
        "ru.keepcoder.Telegram", // Telegram for macOS, the native Swift client
    ]

    public static let `default` = Config(
        apps: defaultApps,
        startDelaySeconds: 5,
        endGraceSeconds: 20,
        creationSource: "application_menu",
        notifyOnStart: true
    )

    public init(apps: [String], startDelaySeconds: Double, endGraceSeconds: Double, creationSource: String, notifyOnStart: Bool) {
        self.apps = apps
        self.startDelaySeconds = startDelaySeconds
        self.endGraceSeconds = endGraceSeconds
        self.creationSource = creationSource
        self.notifyOnStart = notifyOnStart
    }
}

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case apps, startDelaySeconds, endGraceSeconds, creationSource, notifyOnStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config.default
        self.init(
            apps: try container.decodeIfPresent([String].self, forKey: .apps) ?? fallback.apps,
            startDelaySeconds: try container.decodeIfPresent(Double.self, forKey: .startDelaySeconds) ?? fallback.startDelaySeconds,
            endGraceSeconds: try container.decodeIfPresent(Double.self, forKey: .endGraceSeconds) ?? fallback.endGraceSeconds,
            creationSource: try container.decodeIfPresent(String.self, forKey: .creationSource) ?? fallback.creationSource,
            notifyOnStart: try container.decodeIfPresent(Bool.self, forKey: .notifyOnStart) ?? fallback.notifyOnStart
        )
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): return "invalid config: \(reason)"
        }
    }
}

public enum ConfigLoader {
    /// Loads the config file, or returns the defaults when the file does not exist.
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Config {
        let config = try JSONDecoder().decode(Config.self, from: data)
        try validate(config)
        return config
    }

    static func validate(_ config: Config) throws {
        if config.apps.isEmpty { throw ConfigError.invalid("apps must list at least one bundle identifier") }
        if config.startDelaySeconds < 0 { throw ConfigError.invalid("startDelaySeconds must not be negative") }
        if config.endGraceSeconds < 0 { throw ConfigError.invalid("endGraceSeconds must not be negative") }
        if config.creationSource.isEmpty { throw ConfigError.invalid("creationSource must not be empty") }
    }
}

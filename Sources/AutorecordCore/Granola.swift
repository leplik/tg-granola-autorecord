import CryptoKit
import Foundation

/// Everything this tool knows about Granola's desktop app internals.
/// None of it is a public API, so each item names where it comes from.
public enum Granola {
    public static let bundleID = "com.granola.app"

    /// Deep link handled by Granola's `new-document` route. It creates a note and starts
    /// transcription unless `auto_transcribe=0` is passed.
    public static func newNoteURL(creationSource: String) -> URL {
        var components = URLComponents()
        components.scheme = "granola"
        components.host = "new-document"
        components.queryItems = [URLQueryItem(name: "creation_source", value: creationSource)]
        return components.url!
    }

    /// Unix socket that Granola's Google Meet browser extension talks to.
    /// Granola names it after the first 12 hex characters of the SHA-256 of the home directory.
    public static func meetConsentSocketPath(homeDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(homeDirectory.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "/tmp/granola-meet-consent-\(hex.prefix(12)).sock"
    }

    /// Feature flag that makes Granola stop transcribing when the Meet extension reports `meeting-ended`.
    public static let extensionAutoStopFlag = "meet_consent_extension_auto_stop"

    /// Granola ignores `meeting-ended` until the system-audio transcript is at least this old.
    public static let extensionAutoStopMinimumRecording: TimeInterval = 180

    /// One newline-terminated JSON message in the Meet extension's `meeting-ended` format.
    public static func meetingEndedMessage(at date: Date) -> String {
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let message: [String: Any] = [
            "type": "granola:event",
            "event": "meeting-ended",
            "payload": ["meetingCode": NSNull(), "observedAt": millis],
            "timestamp": millis,
        ]
        let data = try! JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func localStateURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Granola", isDirectory: true)
            .appendingPathComponent("local-state.json")
    }

    /// Reads a boolean feature flag from Granola's cached `local-state.json`. Anything but `true` counts as off.
    public static func isFlagEnabled(_ flag: String, localStateJSON: Data) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: localStateJSON) as? [String: Any],
            let flags = root["featureFlags"] as? [String: Any],
            let value = flags[flag] as? Bool
        else { return false }
        return value
    }
}

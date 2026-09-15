import Foundation

enum Notifier {
    static func notify(_ message: String) {
        let script = "display notification \"\(escape(message))\" with title \"Granola autorecord\""
        do {
            try Shell.run("/usr/bin/osascript", ["-e", script])
        } catch {
            Log.warn("could not show notification: \(error)")
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

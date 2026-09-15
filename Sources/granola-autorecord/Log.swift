import Foundation

enum Log {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    static func info(_ message: String) { write("INFO ", message) }
    static func warn(_ message: String) { write("WARN ", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        print("\(formatter.string(from: Date())) \(level) \(message)")
        fflush(stdout)
    }
}

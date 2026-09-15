import Foundation

enum Shell {
    struct Failure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let output: String
        var description: String { "\(command) exited with \(status): \(output)" }
    }

    /// Runs a program to completion and returns its combined output. Throws on a non-zero exit.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(command: ([executable] + arguments).joined(separator: " "), status: process.terminationStatus, output: output)
        }
        return output
    }
}

/// Polls `condition` once per `interval` until it is true or `timeout` passes.
func waitUntil(timeout: TimeInterval, interval: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date() >= deadline { return false }
        Thread.sleep(forTimeInterval: interval)
    }
}

import AutorecordCore
import Foundation
import os

/// Prints to the terminal for interactive commands. The agent also appends to a rotating file
/// and mirrors every line to the unified log, so Console.app shows it under the bundle identifier.
enum Log {
    private static let lock = NSLock()
    private static var file: FileHandle?
    private static var fileURL: URL?
    private static let maxFileBytes: UInt64 = 2 * 1024 * 1024
    private static let system = Logger(subsystem: Product.bundleID, category: "agent")

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    /// Switches from terminal output to the log file. Called once by the agent at startup.
    static func useFile(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        fileURL = url
        openFile()
    }

    static func info(_ message: String) { write("INFO ", message, .info) }
    static func warn(_ message: String) { write("WARN ", message, .default) }
    static func error(_ message: String) { write("ERROR", message, .error) }

    private static func write(_ level: String, _ message: String, _ type: OSLogType) {
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let file {
            // write(contentsOf:) throws instead of raising an Objective-C exception, e.g. on a full disk.
            try? file.write(contentsOf: Data(line.utf8))
            system.log(level: type, "\(message, privacy: .public)")
            rotateIfNeeded(file)
        } else {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private static func openFile() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        file = descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
    }

    /// Keeps one previous file next to the current one: `name.log` and `name.log.1`.
    private static func rotateIfNeeded(_ handle: FileHandle) {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, UInt64(info.st_size) > maxFileBytes, let fileURL else { return }
        try? handle.close()
        let previous = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        openFile()
    }
}

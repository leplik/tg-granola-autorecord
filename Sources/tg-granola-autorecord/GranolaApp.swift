import AppKit
import AutorecordCore
import Darwin
import Foundation

/// The real Granola desktop app, as seen by the agent.
struct GranolaApp: GranolaLauncher, StopRoutes {
    let config: Config
    let homeDirectory: URL

    // MARK: GranolaLauncher

    func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Granola.bundleID) != nil
    }

    func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Granola.bundleID
    }

    /// Opens `granola://new-document`, which creates a note and starts transcribing.
    /// `open -g` keeps Granola in the background so the call window keeps focus.
    func startNewNote() throws {
        let url = Granola.newNoteURL(creationSource: config.creationSource)
        try Shell.run("/usr/bin/open", ["-g", url.absoluteString])
    }

    // MARK: StopRoutes

    func isGranolaRecording() -> Bool {
        AudioSignals.isGranolaRecording(AudioProcesses.snapshot())
    }

    func isExtensionAutoStopEnabled() -> Bool {
        guard let data = try? Data(contentsOf: Granola.localStateURL(homeDirectory: homeDirectory)) else { return false }
        return Granola.isFlagEnabled(Granola.extensionAutoStopFlag, localStateJSON: data)
    }

    /// Sends the Meet extension's `meeting-ended` event to Granola's local socket.
    func sendMeetingEnded() throws {
        let path = Granola.meetConsentSocketPath(homeDirectory: homeDirectory.path)
        try UnixSocket.send(Granola.meetingEndedMessage(at: Date()), to: path)
    }

    func pressStopButton() -> ButtonPressResult {
        GranolaAccessibility.pressStopButton(bringToFront: bringToFront)
    }

    // MARK: Helpers

    func bringToFront() {
        do {
            try Shell.run("/usr/bin/open", ["-b", Granola.bundleID])
        } catch {
            Log.warn("could not bring Granola to the front: \(error)")
        }
    }

    /// Granola's version from its Info.plist, if installed.
    static func installedVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Granola.bundleID) else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

enum UnixSocket {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func send(_ text: String, to path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket(): \(lastError())") }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure(description: "socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure(description: "connect(\(path)): \(lastError())") }

        var remaining = Array(text.utf8)[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw Failure(description: "write(): \(lastError())") }
            remaining = remaining.dropFirst(written)
        }
        // Give Granola a moment to read the line before the connection closes.
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}

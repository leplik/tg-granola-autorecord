import Foundation

enum LaunchAgent {
    static let label = "io.github.leplik.granola-autorecord"

    static func install(homeDirectory: URL) throws {
        let paths = Paths(homeDirectory: homeDirectory)
        let source = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().standardizedFileURL
        let fileManager = FileManager.default

        unload()
        try fileManager.createDirectory(at: paths.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)

        if source != paths.binary.standardizedFileURL {
            if fileManager.fileExists(atPath: paths.binary.path) {
                try fileManager.removeItem(at: paths.binary)
            }
            try fileManager.copyItem(at: source, to: paths.binary)
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [paths.binary.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": paths.log.path,
            "StandardErrorPath": paths.log.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: paths.plist, options: .atomic)

        // launchd may still be tearing down the previous instance, so retry briefly.
        var lastError: Error?
        for _ in 0..<5 {
            do {
                try Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.plist.path])
                lastError = nil
                break
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 1)
            }
        }
        if let lastError { throw lastError }

        print("""
        Installed and started.
          binary: \(paths.binary.path)
          agent:  \(paths.plist.path)
          log:    \(paths.log.path)

        Grant Accessibility access so the agent can press Granola's stop button:
          System Settings > Privacy & Security > Accessibility > enable "granola-autorecord".
        macOS ties that permission to this exact binary. After every reinstall, remove the old entry
        with the minus button and let the agent ask again.
        """)
    }

    static func uninstall(homeDirectory: URL) throws {
        let paths = Paths(homeDirectory: homeDirectory)
        unload()
        let fileManager = FileManager.default
        for url in [paths.plist, paths.binary] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        print("""
        Uninstalled. The log at \(paths.log.path) and any config in ~/.config/granola-autorecord were left in place.
        Remove "granola-autorecord" from System Settings > Privacy & Security > Accessibility by hand.
        """)
    }

    private static func unload() {
        _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }

    private struct Paths {
        let binary: URL
        let plist: URL
        let log: URL

        init(homeDirectory: URL) {
            binary = homeDirectory.appendingPathComponent("Library/Application Support/granola-autorecord/granola-autorecord")
            plist = homeDirectory.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.label).plist")
            log = homeDirectory.appendingPathComponent("Library/Logs/granola-autorecord.log")
        }
    }
}

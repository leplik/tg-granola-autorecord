import AutorecordCore
import Foundation

let usage = """
\(Product.name) \(Product.version)
Starts a Granola recording when a Telegram call begins and stops it when the call ends.

usage: \(Product.command) <command>

  doctor      check the setup and print a report to paste into bug reports
  monitor     show what the call detector sees, without touching Granola
  enable      turn on the background agent (also done by opening the app)
  disable     turn off the background agent
  restart     restart the background agent, e.g. after editing the settings file
  start       start a Granola recording now, as on call start
  stop        stop the recording now, as on call end
  ax-dump     list the buttons Granola exposes to Accessibility
  version     print the version

settings: ~/.config/\(Product.command)/config.json
log:      ~/Library/Logs/\(Product.command).log
"""

let paths = Paths(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
// LaunchServices used to pass a -psn_ argument; ignore it if it appears.
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

func loadConfigOrExit() -> Config {
    do {
        return try ConfigLoader.load(from: paths.config)
    } catch {
        Log.error("cannot read \(paths.config.path): \(error)")
        exit(78) // EX_CONFIG
    }
}

func runOrExit(_ body: () throws -> Void) {
    do {
        try body()
    } catch {
        Log.error("\(error)")
        exit(1)
    }
}

guard arguments.count <= 1 else {
    print(usage)
    exit(64)
}

switch arguments.first {
case nil:
    // Opened from Finder or `open`: no terminal attached.
    if isatty(STDIN_FILENO) == 0 && isatty(STDOUT_FILENO) == 0 {
        Setup.run()
    }
    print(usage)

case "agent":
    AgentController(paths: paths).run()

case "setup":
    Setup.run()

case "doctor":
    exit(Doctor.run(paths: paths))

case "monitor":
    Monitor.run(config: loadConfigOrExit())

case "enable":
    runOrExit {
        try LoginItem.service.register()
        print("Background agent: \(LoginItem.describe(LoginItem.service.status)).")
    }

case "disable":
    runOrExit {
        try LoginItem.service.unregister()
        print("Background agent turned off.")
    }

case "restart":
    runOrExit {
        try LoginItem.restart()
        print("Background agent restarted.")
    }

case "start":
    let config = loadConfigOrExit()
    runOrExit { try GranolaApp(config: config, homeDirectory: paths.homeDirectory).startNewNote() }
    print("Asked Granola to start a recording.")

case "stop":
    let granola = GranolaApp(config: loadConfigOrExit(), homeDirectory: paths.homeDirectory)
    let outcome = StopSequence(routes: granola, time: SystemTime(), log: Log.info).run(recordingStartedAt: .distantPast)
    print(outcome)
    if case .failed = outcome { exit(1) }

case "ax-dump":
    print(GranolaAccessibility.dump())

case "version", "--version", "-v":
    print("\(Product.command) \(Product.version)")

case "help", "--help", "-h":
    print(usage)

default:
    print(usage)
    exit(64)
}

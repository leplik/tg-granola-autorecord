import AutorecordCore
import Foundation

let usage = """
usage: granola-autorecord <command>

Starts a Granola note when a Telegram call begins and stops it when the call ends.

commands:
  run         watch for calls and drive Granola (this is what the LaunchAgent runs)
  monitor     print what the call detector sees, without touching Granola
  start       start a Granola note now, exactly as on call start
  stop        run the stop sequence now, exactly as on call end
  ax-dump     list the buttons Granola exposes to Accessibility
  install     copy this binary into ~/Library/Application Support and start the LaunchAgent
  uninstall   stop the LaunchAgent and remove the installed binary

config file (optional): ~/.config/granola-autorecord/config.json
"""

let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
let arguments = Array(CommandLine.arguments.dropFirst())

func loadConfig() -> Config {
    let url = ConfigLoader.defaultURL(homeDirectory: homeDirectory)
    do {
        return try ConfigLoader.load(from: url)
    } catch {
        Log.error("cannot read \(url.path): \(error)")
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

guard arguments.count == 1 else {
    print(usage)
    exit(arguments.isEmpty ? 0 : 64)
}

switch arguments[0] {
case "run":
    let config = loadConfig()
    Runner(config: config, granola: GranolaApp(config: config, homeDirectory: homeDirectory)).run()

case "monitor":
    Monitor.run(config: loadConfig())

case "start":
    let config = loadConfig()
    runOrExit { try GranolaApp(config: config, homeDirectory: homeDirectory).startNewNote() }
    print("Asked Granola to start a new note.")

case "stop":
    let config = loadConfig()
    let granola = GranolaApp(config: config, homeDirectory: homeDirectory)
    let isRecording = { AudioSignals.isGranolaRecording(AudioProcesses.snapshot()) }
    let outcome = Stopper(granola: granola, isRecording: isRecording).stop(recordingStartedAt: .distantPast)
    print(outcome.rawValue)
    exit(outcome == .manual ? 1 : 0)

case "ax-dump":
    print(GranolaAccessibility.dump())

case "install":
    runOrExit { try LaunchAgent.install(homeDirectory: homeDirectory) }

case "uninstall":
    runOrExit { try LaunchAgent.uninstall(homeDirectory: homeDirectory) }

case "help", "-h", "--help":
    print(usage)

default:
    print(usage)
    exit(64)
}

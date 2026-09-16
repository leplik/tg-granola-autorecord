import AutorecordCore
import Foundation
import UserNotifications

let usage = """
\(Product.name) \(Product.version)
Starts a Granola recording when a Telegram call begins and stops it when the call ends.

usage: \(Product.command) <command>

  doctor      check the setup and print a report to paste into bug reports
  monitor     show what the call detector sees, without touching Granola
  enable      turn the app on: start it now and at every login
  disable     turn the app off: quit it and stop starting it at login
  restart     restart the app, e.g. after editing the settings file
  start       start a Granola recording now, as on call start
  stop        stop the recording now, as on call end
  test-notification  send a notification, to check that they are allowed
  ax-dump     list the buttons Granola exposes to Accessibility
  version     print the version

settings: ~/.config/\(Product.command)/config.json
log:      ~/Library/Logs/\(Product.command).log
"""

/// Homebrew links the command into its bin directory. Called through that symlink, `Bundle.main` is the
/// bin directory instead of the app, and ServiceManagement cannot find the agent. Re-run from the bundle.
func reexecFromAppBundleIfNeeded() {
    guard Bundle.main.bundleURL.pathExtension != "app", let invoked = Bundle.main.executableURL else { return }
    let real = invoked.resolvingSymlinksInPath()
    guard real.path != invoked.path, real.path.contains(".app/Contents/MacOS/") else { return }
    var cArguments: [UnsafeMutablePointer<CChar>?] = [strdup(real.path)]
    cArguments += CommandLine.arguments.dropFirst().map { strdup($0) }
    cArguments.append(nil)
    execv(real.path, cArguments)
    // execv only returns on failure; carry on from here.
}

reexecFromAppBundleIfNeeded()

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
    // Started by LaunchServices (Finder, `open`, login) has no terminal attached.
    if isatty(STDIN_FILENO) == 0 && isatty(STDOUT_FILENO) == 0 {
        AppController.run(paths: paths)
    }
    print(usage)

case "doctor":
    exit(Doctor.run(paths: paths))

case "monitor":
    Monitor.run(config: loadConfigOrExit())

case "enable":
    runOrExit {
        Preferences.turnedOffByUser = false
        if let error = LoginItem.ensureRegistered() { throw error }
        if RunningApp.pids().isEmpty { try RunningApp.launch() }
        print("On: \(LoginItem.describe(LoginItem.service.status)).")
    }

case "disable":
    runOrExit {
        Preferences.turnedOffByUser = true
        RunningApp.stop()
        FileOwnedRecordingStore(url: paths.ownedRecording).save(nil)
        if LoginItem.service.status != .notRegistered && LoginItem.service.status != .notFound {
            try LoginItem.service.unregister()
        }
        print("Off: the app is not running and does not start at login.")
    }

case "restart":
    runOrExit {
        RunningApp.stop()
        try RunningApp.launch()
        print("Restarted.")
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

case "test-notification":
    let semaphore = DispatchSemaphore(value: 0)
    let content = UNMutableNotificationContent()
    content.title = "Test notification"
    content.body = "Notifications from \(Product.name) work."
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) { error in
        print(error.map { "could not show the notification: \($0.localizedDescription)" } ?? "Sent a test notification.")
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)

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

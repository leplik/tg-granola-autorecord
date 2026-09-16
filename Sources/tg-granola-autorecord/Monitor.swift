import AutorecordCore
import Foundation

/// `monitor`: shows what the call detector sees, without touching Granola.
enum Monitor {
    static func run(config: Config) -> Never {
        let watchedApps = Set(config.apps)
        Log.info("watching \(config.apps.joined(separator: ", ")); press Ctrl+C to quit")
        var lastLine = ""
        while true {
            let snapshot = AudioProcesses.snapshot()
            let apps = snapshot.filter { $0.bundleID.map(watchedApps.contains) ?? false }
            let appText = apps.isEmpty
                ? "Telegram: no audio activity"
                : apps.map { "\($0.bundleID ?? "?") mic=\(onOff($0.isRunningInput)) speaker=\(onOff($0.isRunningOutput))" }
                    .joined(separator: "; ")
            let signal = AudioSignals.callSignal(snapshot, watchedApps: watchedApps)
            let recording = AudioSignals.isGranolaRecording(snapshot)
            let line = "\(appText) | call signal: \(signal.rawValue) | Granola recording: \(recording ? "yes" : "no")"
            if line != lastLine {
                Log.info(line)
                lastLine = line
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }
}

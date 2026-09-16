import AutorecordCore
import Foundation

/// The long-running loop behind `granola-autorecord run`.
struct Runner {
    let config: Config
    let granola: GranolaApp

    static let startWait: TimeInterval = 45

    func run() -> Never {
        Log.info("started, watching \(config.apps.joined(separator: ", "))")
        if !GranolaAccessibility.isTrusted(prompt: true) {
            Log.warn("no Accessibility permission: the stop-button route stays off until it is granted in System Settings > Privacy & Security > Accessibility")
        }

        let watchedApps = Set(config.apps)
        let isRecording = { AudioSignals.isGranolaRecording(AudioProcesses.snapshot()) }
        var tracker = CallTracker(startDelay: config.startDelaySeconds, endGrace: config.endGraceSeconds)
        var loggedPhase = tracker.phase

        while true {
            let snapshot = AudioProcesses.snapshot()
            let signal = AudioSignals.callSignal(snapshot, watchedApps: watchedApps)
            let recording = AudioSignals.isGranolaRecording(snapshot)
            let command = tracker.step(now: Date(), signal: signal, granolaRecording: recording)
            logTransition(from: &loggedPhase, to: tracker.phase, context: "call signal: \(signal.rawValue), Granola recording: \(recording)")

            switch command {
            case .startRecording?:
                start(&tracker, isRecording: isRecording)
            case .stopRecording(let startedAt)?:
                Log.info("call ended, stopping Granola")
                let outcome = Stopper(granola: granola, isRecording: isRecording).stop(recordingStartedAt: startedAt)
                Log.info("stop finished: \(outcome.rawValue)")
                tracker.stopFinished()
            case nil:
                break
            }
            // The observation above is stale once a command has run, so log the new phase on its own.
            logTransition(from: &loggedPhase, to: tracker.phase, context: nil)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func start(_ tracker: inout CallTracker, isRecording: () -> Bool) {
        Log.info("call detected, asking Granola to start a note")
        do {
            try granola.startNewNote()
        } catch {
            Log.error("could not open the Granola deep link: \(error)")
            Notifier.notify("Call detected, but Granola could not be opened.")
            tracker.startFailed()
            return
        }
        if waitUntil(timeout: Self.startWait, isRecording) {
            Log.info("Granola is recording")
            tracker.startSucceeded(at: Date())
        } else {
            Log.error("Granola did not start recording within \(Int(Self.startWait)) s")
            Notifier.notify("Call detected, but Granola did not start recording.")
            tracker.startFailed()
        }
    }

    private func logTransition(from logged: inout CallTracker.Phase, to phase: CallTracker.Phase, context: String?) {
        guard phase != logged else { return }
        Log.info("\(logged) -> \(phase)" + (context.map { " (\($0))" } ?? ""))
        logged = phase
    }
}

/// `granola-autorecord monitor`: shows what the detector sees, without touching Granola.
enum Monitor {
    static func run(config: Config) -> Never {
        let watchedApps = Set(config.apps)
        Log.info("watching \(config.apps.joined(separator: ", ")); press Ctrl+C to quit")
        var lastLine = ""
        while true {
            let snapshot = AudioProcesses.snapshot()
            let apps = snapshot.filter { $0.bundleID.map(watchedApps.contains) ?? false }
            let appText = apps.isEmpty
                ? "watched apps: no audio activity"
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

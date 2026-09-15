import Foundation

/// What CoreAudio reports about one process at a single moment.
public struct AudioProcessState: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var executablePath: String?
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(pid: Int32, bundleID: String?, executablePath: String?, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// How strongly the watched apps look like they are in a call.
public enum CallSignal: String, Equatable, Sendable {
    /// Neither microphone nor speaker is in use.
    case none
    /// Only one of microphone or speaker is in use: a voice message, a video, or a call with a muted side.
    case partial
    /// Microphone and speaker are both in use, which is what a live call looks like.
    case full
}

public enum AudioSignals {
    public static func callSignal(_ processes: [AudioProcessState], watchedApps: Set<String>) -> CallSignal {
        let watched = processes.filter { process in
            guard let bundleID = process.bundleID else { return false }
            return watchedApps.contains(bundleID)
        }
        let input = watched.contains { $0.isRunningInput }
        let output = watched.contains { $0.isRunningOutput }
        switch (input, output) {
        case (true, true): return .full
        case (false, false): return .none
        default: return .partial
        }
    }

    public static func isGranola(_ process: AudioProcessState) -> Bool {
        if let bundleID = process.bundleID, bundleID.hasPrefix(Granola.bundleID) { return true }
        if let path = process.executablePath, path.contains("/Granola.app/") { return true }
        return false
    }

    /// Granola holds the microphone only while it transcribes, so an open input means a recording is running.
    public static func isGranolaRecording(_ processes: [AudioProcessState]) -> Bool {
        processes.contains { isGranola($0) && $0.isRunningInput }
    }
}

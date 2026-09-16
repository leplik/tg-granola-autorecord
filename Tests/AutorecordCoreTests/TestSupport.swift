import AutorecordCore
import Foundation

final class FakeTime: TimeSource {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = now
    }

    func sleep(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

struct FakeError: Error, CustomStringConvertible {
    var description: String { "fake failure" }
}

/// Telegram, Granola and the stop routes, all controlled by the test.
final class FakeWorld: AudioSource, GranolaLauncher, StopRoutes {
    var telegramMic = false
    var telegramSpeaker = false
    var granolaRecording = false

    var installed = true
    var frontmost = false
    var deepLinkFails = false
    var startsRecordingOnDeepLink = true
    var extensionAutoStopEnabled = false
    var socketFails = false
    var socketStopsRecording = true
    var buttonResult: ButtonPressResult = .pressed
    var buttonStopsRecording = true
    /// Runs inside `pressStopButton`, e.g. to simulate someone else stopping the recording meanwhile.
    var onButtonPress: (() -> Void)?

    private(set) var deepLinksOpened = 0
    private(set) var meetingEndedSent = 0
    private(set) var buttonPresses = 0

    var callActive: Bool {
        get { telegramMic && telegramSpeaker }
        set {
            telegramMic = newValue
            telegramSpeaker = newValue
        }
    }

    func snapshot() -> [AudioProcessState] {
        [
            AudioProcessState(pid: 10, bundleID: "com.tdesktop.Telegram", executablePath: nil, isRunningInput: telegramMic, isRunningOutput: telegramSpeaker),
            AudioProcessState(pid: 20, bundleID: "com.granola.app", executablePath: nil, isRunningInput: granolaRecording, isRunningOutput: false),
        ]
    }

    func isInstalled() -> Bool { installed }
    func isFrontmost() -> Bool { frontmost }

    func startNewNote() throws {
        deepLinksOpened += 1
        if deepLinkFails { throw FakeError() }
        if startsRecordingOnDeepLink { granolaRecording = true }
    }

    func isGranolaRecording() -> Bool { granolaRecording }
    func isExtensionAutoStopEnabled() -> Bool { extensionAutoStopEnabled }

    func sendMeetingEnded() throws {
        meetingEndedSent += 1
        if socketFails { throw FakeError() }
        if socketStopsRecording { granolaRecording = false }
    }

    func pressStopButton() -> ButtonPressResult {
        buttonPresses += 1
        onButtonPress?()
        if buttonResult == .pressed && buttonStopsRecording { granolaRecording = false }
        return buttonResult
    }
}

final class RecordingPresenter: NoticePresenter {
    private(set) var notices: [AgentNotice] = []

    func present(_ notice: AgentNotice) {
        notices.append(notice)
    }
}

final class MemoryStore: OwnedRecordingStore {
    var stored: Date?

    func load() -> Date? { stored }

    func save(_ recordingStartedAt: Date?) {
        stored = recordingStartedAt
    }
}

final class Harness {
    let time = FakeTime()
    let world = FakeWorld()
    let presenter = RecordingPresenter()
    let store = MemoryStore()
    private(set) var logs: [String] = []

    func makeAgent(config: Config = .default) -> Agent {
        Agent(
            config: config,
            audio: world,
            granola: world,
            stopRoutes: world,
            presenter: presenter,
            ownedRecording: store,
            time: time,
            log: { [weak self] in self?.logs.append($0) }
        )
    }

    /// Ticks once per simulated second.
    func run(_ agent: Agent, seconds: Int) {
        for _ in 0..<seconds {
            agent.tick()
            time.sleep(seconds: 1)
        }
    }
}

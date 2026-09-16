import AutorecordCore
import XCTest

final class AudioSignalsTests: XCTestCase {
    private func process(_ bundleID: String?, path: String? = nil, input: Bool = false, output: Bool = false) -> AudioProcessState {
        AudioProcessState(pid: 1, bundleID: bundleID, executablePath: path, isRunningInput: input, isRunningOutput: output)
    }

    private let telegram: Set<String> = ["com.tdesktop.Telegram"]

    func testCallSignalLevels() {
        XCTAssertEqual(AudioSignals.callSignal([process("com.tdesktop.Telegram")], watchedApps: telegram), .none)
        XCTAssertEqual(AudioSignals.callSignal([process("com.tdesktop.Telegram", input: true)], watchedApps: telegram), .partial)
        XCTAssertEqual(AudioSignals.callSignal([process("com.tdesktop.Telegram", output: true)], watchedApps: telegram), .partial)
        XCTAssertEqual(AudioSignals.callSignal([process("com.tdesktop.Telegram", input: true, output: true)], watchedApps: telegram), .full)
    }

    func testCallSignalCombinesProcessesOfWatchedAppsOnly() {
        let processes = [
            process("com.tdesktop.Telegram", input: true),
            process("com.tdesktop.Telegram", output: true),
            process("com.spotify.client", input: true, output: true),
            process(nil, input: true, output: true),
        ]
        XCTAssertEqual(AudioSignals.callSignal(processes, watchedApps: telegram), .full)
        XCTAssertEqual(AudioSignals.callSignal(Array(processes.dropFirst(2)), watchedApps: telegram), .none)
    }

    func testGranolaRecordingNeedsMicrophoneInput() {
        XCTAssertFalse(AudioSignals.isGranolaRecording([process("com.granola.app", output: true)]))
        XCTAssertTrue(AudioSignals.isGranolaRecording([process("com.granola.app", input: true)]))
        XCTAssertTrue(AudioSignals.isGranolaRecording([process("com.granola.app.helper", input: true)]))
        XCTAssertTrue(AudioSignals.isGranolaRecording([
            process(nil, path: "/Applications/Granola.app/Contents/Frameworks/Granola Helper.app/Contents/MacOS/Granola Helper", input: true),
        ]))
        XCTAssertFalse(AudioSignals.isGranolaRecording([process("com.tdesktop.Telegram", input: true)]))
    }
}

final class GranolaTests: XCTestCase {
    func testSocketPathMatchesGranolaNaming() {
        // printf '%s' /Users/leplik | shasum -a 256 | cut -c1-12
        XCTAssertEqual(Granola.meetConsentSocketPath(homeDirectory: "/Users/leplik"), "/tmp/granola-meet-consent-9638bf154409.sock")
    }

    func testNewNoteURL() {
        XCTAssertEqual(
            Granola.newNoteURL(creationSource: "application_menu").absoluteString,
            "granola://new-document?creation_source=application_menu"
        )
    }

    func testMeetingEndedMessageShape() throws {
        let line = Granola.meetingEndedMessage(at: Date(timeIntervalSince1970: 1_700_000_000.25))
        XCTAssertTrue(line.hasSuffix("\n"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "granola:event")
        XCTAssertEqual(json["event"] as? String, "meeting-ended")
        XCTAssertEqual(json["timestamp"] as? Int64, 1_700_000_000_250)
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertTrue(payload["meetingCode"] is NSNull)
        XCTAssertEqual(payload["observedAt"] as? Int64, 1_700_000_000_250)
    }

    func testFlagReading() {
        let json = Data("""
        {"featureFlags":{"meet_consent_extension_auto_stop":true,"off":false,"object":{"timeoutMs":900000}}}
        """.utf8)
        XCTAssertTrue(Granola.isFlagEnabled("meet_consent_extension_auto_stop", localStateJSON: json))
        XCTAssertFalse(Granola.isFlagEnabled("off", localStateJSON: json))
        XCTAssertFalse(Granola.isFlagEnabled("object", localStateJSON: json))
        XCTAssertFalse(Granola.isFlagEnabled("missing", localStateJSON: json))
        XCTAssertFalse(Granola.isFlagEnabled("anything", localStateJSON: Data("not json".utf8)))
    }
}

final class StopButtonMatcherTests: XCTestCase {
    private let stopClasses = ["group/button", "relative", "flex", "min-w-10", "pr-[3px]", "pl-0", "items-center"]
    private let pillClasses = ["group/button", "relative", "flex", "px-1", "min-w-[48px]"]

    func testPicksStructuralMatchNextToTranscriptPill() {
        let candidates = [
            StopButtonCandidate(button: AXButtonInfo(classes: pillClasses), siblingClasses: []),
            StopButtonCandidate(button: AXButtonInfo(classes: stopClasses), siblingClasses: Set(pillClasses)),
        ]
        XCTAssertEqual(StopButtonMatcher.pick(candidates), 1)
    }

    func testIgnoresLookalikeWithoutTranscriptPill() {
        let candidates = [StopButtonCandidate(button: AXButtonInfo(classes: stopClasses), siblingClasses: ["px-1"])]
        XCTAssertNil(StopButtonMatcher.pick(candidates))
    }

    func testRefusesAmbiguousStructuralMatches() {
        let candidate = StopButtonCandidate(button: AXButtonInfo(classes: stopClasses), siblingClasses: Set(pillClasses))
        XCTAssertNil(StopButtonMatcher.pick([candidate, candidate]))
    }

    func testExplicitLabelWinsOverStructure() {
        let candidates = [
            StopButtonCandidate(button: AXButtonInfo(classes: stopClasses), siblingClasses: Set(pillClasses)),
            StopButtonCandidate(button: AXButtonInfo(help: "Stop transcript"), siblingClasses: []),
        ]
        XCTAssertEqual(StopButtonMatcher.pick(candidates), 1)
    }

    func testLabelMatchingIsCaseInsensitiveAndChecksAllNames() {
        XCTAssertTrue(StopButtonMatcher.hasStopLabel(AXButtonInfo(title: "STOP TRANSCRIBING")))
        XCTAssertTrue(StopButtonMatcher.hasStopLabel(AXButtonInfo(label: "Stop transcript")))
        XCTAssertFalse(StopButtonMatcher.hasStopLabel(AXButtonInfo(title: "Stop rewriting")))
        XCTAssertFalse(StopButtonMatcher.hasStopLabel(AXButtonInfo(label: "Copy transcript")))
        XCTAssertFalse(StopButtonMatcher.hasStopLabel(AXButtonInfo(title: "Why we stop transcribing")))
        XCTAssertTrue(StopButtonMatcher.hasStopLabel(AXButtonInfo(help: "  Stop transcript\n")))
    }

    func testAmbiguousLabelsFallBackToStructure() {
        let candidates = [
            StopButtonCandidate(button: AXButtonInfo(title: "Stop transcript"), siblingClasses: []),
            StopButtonCandidate(button: AXButtonInfo(label: "Stop transcribing"), siblingClasses: []),
            StopButtonCandidate(button: AXButtonInfo(classes: stopClasses), siblingClasses: Set(pillClasses)),
        ]
        XCTAssertEqual(StopButtonMatcher.pick(candidates), 2)
    }
}

final class ConfigTests: XCTestCase {
    func testEmptyObjectGivesDefaults() throws {
        XCTAssertEqual(try ConfigLoader.decode(Data("{}".utf8)), .default)
    }

    func testPartialOverride() throws {
        let config = try ConfigLoader.decode(Data(#"{"apps":["net.whatsapp.WhatsApp"],"endGraceSeconds":45}"#.utf8))
        XCTAssertEqual(config.apps, ["net.whatsapp.WhatsApp"])
        XCTAssertEqual(config.endGraceSeconds, 45)
        XCTAssertEqual(config.startDelaySeconds, Config.default.startDelaySeconds)
        XCTAssertEqual(config.creationSource, Config.default.creationSource)
    }

    func testRejectsInvalidValues() {
        XCTAssertThrowsError(try ConfigLoader.decode(Data(#"{"apps":[]}"#.utf8)))
        XCTAssertThrowsError(try ConfigLoader.decode(Data(#"{"startDelaySeconds":-1}"#.utf8)))
        XCTAssertThrowsError(try ConfigLoader.decode(Data(#"{"endGraceSeconds":-1}"#.utf8)))
        XCTAssertThrowsError(try ConfigLoader.decode(Data(#"{"creationSource":""}"#.utf8)))
    }

    func testNotificationsCanBeTurnedOff() throws {
        XCTAssertFalse(try ConfigLoader.decode(Data(#"{"notifyOnStart":false}"#.utf8)).notifyOnStart)
        XCTAssertTrue(Config.default.notifyOnStart)
    }

    func testPathsLiveUnderTheCommandName() {
        let paths = Paths(homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(paths.config.path, "/Users/someone/.config/tg-granola-autorecord/config.json")
        XCTAssertEqual(paths.log.path, "/Users/someone/Library/Logs/tg-granola-autorecord.log")
        XCTAssertEqual(paths.status.path, "/Users/someone/Library/Application Support/tg-granola-autorecord/status.json")
    }

    func testMissingFileGivesDefaults() throws {
        let url = URL(fileURLWithPath: "/nonexistent/granola-autorecord/config.json")
        XCTAssertEqual(try ConfigLoader.load(from: url), .default)
    }
}

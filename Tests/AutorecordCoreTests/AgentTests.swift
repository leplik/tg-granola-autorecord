import AutorecordCore
import XCTest

final class AgentTests: XCTestCase {
    func testRecordsACallEndToEnd() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.callActive = true
        h.run(agent, seconds: 10)

        XCTAssertEqual(h.world.deepLinksOpened, 1)
        XCTAssertTrue(h.world.granolaRecording)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted])
        XCTAssertNotNil(h.store.stored)

        h.run(agent, seconds: 60)
        h.world.callActive = false
        h.run(agent, seconds: 25)

        XCTAssertEqual(h.world.buttonPresses, 1)
        XCTAssertFalse(h.world.granolaRecording)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted])
        XCTAssertNil(h.store.stored)
        XCTAssertEqual(agent.tracker.phase, .idle)
    }

    func testStartNoticeCanBeTurnedOff() {
        let h = Harness()
        var config = Config.default
        config.notifyOnStart = false
        let agent = h.makeAgent(config: config)
        h.world.callActive = true
        h.run(agent, seconds: 10)
        XCTAssertTrue(h.world.granolaRecording)
        XCTAssertEqual(h.presenter.notices, [])
    }

    func testShortBlipDoesNotStartRecording() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.callActive = true
        h.run(agent, seconds: 3)
        h.world.callActive = false
        h.run(agent, seconds: 30)
        XCTAssertEqual(h.world.deepLinksOpened, 0)
    }

    func testVoiceMessageWithMicrophoneOnlyDoesNotStartRecording() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.telegramMic = true
        h.run(agent, seconds: 120)
        XCTAssertEqual(h.world.deepLinksOpened, 0)
    }

    func testLeavesARecordingItDidNotStartAlone() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.granolaRecording = true
        h.world.callActive = true
        h.run(agent, seconds: 100)
        h.world.callActive = false
        h.run(agent, seconds: 60)
        XCTAssertEqual(h.world.deepLinksOpened, 0)
        XCTAssertEqual(h.world.buttonPresses, 0)
        XCTAssertTrue(h.world.granolaRecording)
        XCTAssertEqual(h.presenter.notices, [])
    }

    // MARK: Start failures

    func testGranolaNotInstalledIsReportedOncePerCall() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.installed = false
        h.world.callActive = true
        h.run(agent, seconds: 120)
        XCTAssertEqual(h.world.deepLinksOpened, 0)
        XCTAssertEqual(h.presenter.notices, [.granolaNotInstalled])
    }

    func testDeepLinkFailureIsReported() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.deepLinkFails = true
        h.world.callActive = true
        h.run(agent, seconds: 10)
        XCTAssertEqual(h.presenter.notices, [.startFailed(.couldNotOpenGranola)])
    }

    func testRecordingThatNeverStartsIsReportedAndNotStopped() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.startsRecordingOnDeepLink = false
        h.world.callActive = true
        h.run(agent, seconds: 10)
        XCTAssertEqual(h.presenter.notices, [.startFailed(.didNotStartRecording)])
        h.world.callActive = false
        h.run(agent, seconds: 60)
        XCTAssertEqual(h.world.deepLinksOpened, 1)
        XCTAssertEqual(h.world.buttonPresses, 0)
    }

    // MARK: Stop routes

    func testSocketRouteIsUsedForLongRecordingsWhenGranolaAllowsIt() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.extensionAutoStopEnabled = true
        h.world.callActive = true
        h.run(agent, seconds: 200)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(h.world.meetingEndedSent, 1)
        XCTAssertEqual(h.world.buttonPresses, 0)
        XCTAssertFalse(h.world.granolaRecording)
    }

    func testSocketRouteIsSkippedForShortRecordings() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.extensionAutoStopEnabled = true
        h.world.callActive = true
        h.run(agent, seconds: 60)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(h.world.meetingEndedSent, 0)
        XCTAssertEqual(h.world.buttonPresses, 1)
    }

    func testIgnoredSocketEventFallsBackToButton() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.extensionAutoStopEnabled = true
        h.world.socketStopsRecording = false
        h.world.callActive = true
        h.run(agent, seconds: 200)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(h.world.meetingEndedSent, 1)
        XCTAssertEqual(h.world.buttonPresses, 1)
        XCTAssertFalse(h.world.granolaRecording)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted])
    }

    func testMissingButtonIsReported() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.buttonResult = .notFound(buttonsSeen: 12)
        h.world.callActive = true
        h.run(agent, seconds: 30)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertTrue(h.world.granolaRecording)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted, .stopFailed(.notFound(buttonsSeen: 12))])
        XCTAssertEqual(agent.tracker.phase, .idle)
        XCTAssertNil(h.store.stored)
    }

    func testMissingAccessibilityPermissionIsReported() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.buttonResult = .notTrusted
        h.world.callActive = true
        h.run(agent, seconds: 30)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(h.presenter.notices.last, .stopFailed(.notTrusted))
    }

    // MARK: Granola stopping by itself

    func testGranolaStoppingOnItsOwnIsReportedAndNotRestarted() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.callActive = true
        h.run(agent, seconds: 8)
        h.world.granolaRecording = false
        h.run(agent, seconds: 60)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted, .recordingStoppedByGranola])
        XCTAssertEqual(h.world.deepLinksOpened, 1)
        h.world.callActive = false
        h.run(agent, seconds: 30)
        XCTAssertEqual(h.world.buttonPresses, 0)
        XCTAssertEqual(agent.tracker.phase, .idle)
    }

    func testStoppingByHandInGranolaIsNotReported() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.callActive = true
        h.run(agent, seconds: 30)
        h.world.frontmost = true
        h.world.granolaRecording = false
        h.run(agent, seconds: 2)
        h.world.frontmost = false
        h.run(agent, seconds: 30)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted])
        XCTAssertEqual(h.world.deepLinksOpened, 1)
    }

    func testBriefGranolaDropoutKeepsOwnership() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.callActive = true
        h.run(agent, seconds: 30)
        h.world.granolaRecording = false
        h.run(agent, seconds: 3)
        h.world.granolaRecording = true
        h.run(agent, seconds: 30)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(h.world.buttonPresses, 1)
        XCTAssertEqual(h.presenter.notices, [.recordingStarted])
    }

    // MARK: Stop from the notification

    func testStopFromNotificationHoldsOffUntilTheNextCall() {
        let h = Harness()
        let agent = h.makeAgent()
        h.world.callActive = true
        h.run(agent, seconds: 30)

        agent.requestStop()
        XCTAssertEqual(h.world.buttonPresses, 1)
        XCTAssertFalse(h.world.granolaRecording)
        XCTAssertNil(h.store.stored)

        h.run(agent, seconds: 60)
        XCTAssertEqual(h.world.deepLinksOpened, 1)

        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(agent.tracker.phase, .idle)

        h.world.callActive = true
        h.run(agent, seconds: 10)
        XCTAssertEqual(h.world.deepLinksOpened, 2)
    }

    func testStopRequestWithoutARecordingDoesNothing() {
        let h = Harness()
        let agent = h.makeAgent()
        agent.requestStop()
        XCTAssertEqual(h.world.buttonPresses, 0)
    }

    // MARK: Restarts

    func testResumesResponsibilityAfterRestart() {
        let h = Harness()
        let startedAt = h.time.now.addingTimeInterval(-600)
        h.store.stored = startedAt
        h.world.granolaRecording = true
        h.world.callActive = true

        let agent = h.makeAgent()
        XCTAssertEqual(agent.tracker.phase, .recording(startedAt: startedAt))

        h.run(agent, seconds: 10)
        h.world.callActive = false
        h.run(agent, seconds: 25)
        XCTAssertEqual(h.world.buttonPresses, 1)
        XCTAssertEqual(h.world.deepLinksOpened, 0)
    }

    func testDoesNotResumeStaleOrFinishedRecordings() {
        let stale = Harness()
        stale.store.stored = stale.time.now.addingTimeInterval(-13 * 3600)
        stale.world.granolaRecording = true
        XCTAssertEqual(stale.makeAgent().tracker.phase, .idle)
        XCTAssertNil(stale.store.stored)

        let finished = Harness()
        finished.store.stored = finished.time.now.addingTimeInterval(-600)
        XCTAssertEqual(finished.makeAgent().tracker.phase, .idle)
        XCTAssertNil(finished.store.stored)
    }
}

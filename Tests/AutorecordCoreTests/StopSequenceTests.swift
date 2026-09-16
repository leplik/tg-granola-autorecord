import AutorecordCore
import XCTest

final class StopSequenceTests: XCTestCase {
    private func run(_ world: FakeWorld, time: FakeTime = FakeTime(), startedAgo: TimeInterval = 600) -> StopOutcome {
        StopSequence(routes: world, time: time, log: { _ in })
            .run(recordingStartedAt: time.now.addingTimeInterval(-startedAgo))
    }

    func testNothingToDoWhenGranolaIsNotRecording() {
        let world = FakeWorld()
        XCTAssertEqual(run(world), .alreadyStopped)
        XCTAssertEqual(world.buttonPresses, 0)
    }

    func testSocketFailureFallsBackToButton() {
        let world = FakeWorld()
        world.granolaRecording = true
        world.extensionAutoStopEnabled = true
        world.socketFails = true
        XCTAssertEqual(run(world), .stoppedViaButton)
        XCTAssertEqual(world.meetingEndedSent, 1)
    }

    func testSocketIsNotUsedWhenFlagIsOff() {
        let world = FakeWorld()
        world.granolaRecording = true
        XCTAssertEqual(run(world), .stoppedViaButton)
        XCTAssertEqual(world.meetingEndedSent, 0)
    }

    func testIneffectivePressIsAFailureAfterWaiting() {
        let world = FakeWorld()
        world.granolaRecording = true
        world.buttonStopsRecording = false
        let time = FakeTime()
        let before = time.now
        XCTAssertEqual(run(world, time: time), .failed(.pressed))
        XCTAssertGreaterThanOrEqual(time.now.timeIntervalSince(before), StopSequence.buttonWait)
    }

    func testRecordingStoppedMeanwhileCountsAsStopped() {
        let world = FakeWorld()
        world.granolaRecording = true
        world.buttonResult = .notFound(buttonsSeen: 3)
        world.onButtonPress = { world.granolaRecording = false }
        XCTAssertEqual(run(world), .alreadyStopped)
    }

    func testBriefDropoutAtStopTimeStillPresses() {
        let world = FakeWorld()
        world.onRecordingCheck = { checks in
            if checks == 3 { world.granolaRecording = true }
        }
        XCTAssertEqual(run(world), .stoppedViaButton)
        XCTAssertEqual(world.buttonPresses, 1)
    }

    func testPressReportedAsFailedButEffectiveCountsAsStopped() {
        let world = FakeWorld()
        world.granolaRecording = true
        world.buttonResult = .failed(code: -25204)
        XCTAssertEqual(run(world), .stoppedViaButton)
    }

    func testRecordingThatEndsBeforeThePressIsNotPressed() {
        let world = FakeWorld()
        world.granolaRecording = true
        world.extensionAutoStopEnabled = true
        world.socketFails = true
        world.onRecordingCheck = { checks in
            if checks == 2 { world.granolaRecording = false }
        }
        XCTAssertEqual(run(world), .alreadyStopped)
        XCTAssertEqual(world.buttonPresses, 0)
    }
}

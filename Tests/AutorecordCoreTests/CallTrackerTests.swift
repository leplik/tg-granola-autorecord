import AutorecordCore
import XCTest

final class CallTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func makeTracker(startDelay: TimeInterval = 5, endGrace: TimeInterval = 20) -> CallTracker {
        CallTracker(startDelay: startDelay, endGrace: endGrace)
    }

    /// Drives the tracker into `.recording` as if a call started at t0 and Granola started at t0+6.
    private func recordingTracker() -> CallTracker {
        var tracker = makeTracker()
        XCTAssertNil(tracker.step(now: at(0), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.step(now: at(5), signal: .full, granolaRecording: false), .startRecording)
        tracker.startSucceeded(at: at(6))
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
        return tracker
    }

    func testStartsAfterDelayWhenMicAndSpeakerStayOpen() {
        var tracker = makeTracker()
        XCTAssertNil(tracker.step(now: at(0), signal: .full, granolaRecording: false))
        XCTAssertNil(tracker.step(now: at(4.9), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.step(now: at(5), signal: .full, granolaRecording: false), .startRecording)
        XCTAssertEqual(tracker.phase, .awaitingStart)
    }

    func testZeroDelayStartsOnFirstObservation() {
        var tracker = makeTracker(startDelay: 0)
        XCTAssertEqual(tracker.step(now: at(0), signal: .full, granolaRecording: false), .startRecording)
    }

    func testPartialSignalNeverStartsRecording() {
        var tracker = makeTracker()
        for second in 0..<60 {
            XCTAssertNil(tracker.step(now: at(TimeInterval(second)), signal: .partial, granolaRecording: false))
        }
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testBlipShorterThanDelayResetsCountdown() {
        var tracker = makeTracker()
        XCTAssertNil(tracker.step(now: at(0), signal: .full, granolaRecording: false))
        XCTAssertNil(tracker.step(now: at(3), signal: .partial, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertNil(tracker.step(now: at(4), signal: .full, granolaRecording: false))
        XCTAssertNil(tracker.step(now: at(8), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.step(now: at(9), signal: .full, granolaRecording: false), .startRecording)
    }

    func testDoesNotStartWhenGranolaIsAlreadyRecording() {
        var tracker = makeTracker()
        XCTAssertNil(tracker.step(now: at(0), signal: .full, granolaRecording: true))
        XCTAssertNil(tracker.step(now: at(5), signal: .full, granolaRecording: true))
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
    }

    func testNeverStopsARecordingItDidNotStart() {
        var tracker = makeTracker()
        _ = tracker.step(now: at(0), signal: .full, granolaRecording: true)
        _ = tracker.step(now: at(5), signal: .full, granolaRecording: true)
        for second in 6..<120 {
            XCTAssertNil(tracker.step(now: at(TimeInterval(second)), signal: .none, granolaRecording: true))
        }
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testStopsAfterGraceOnceCallGoesSilent() {
        var tracker = recordingTracker()
        XCTAssertNil(tracker.step(now: at(100), signal: .none, granolaRecording: true))
        XCTAssertEqual(tracker.phase, .callEnding(since: at(100), recordingStartedAt: at(6)))
        XCTAssertNil(tracker.step(now: at(119), signal: .none, granolaRecording: true))
        XCTAssertEqual(tracker.step(now: at(120), signal: .none, granolaRecording: true), .stopRecording(recordingStartedAt: at(6)))
        XCTAssertEqual(tracker.phase, .awaitingStop)
        tracker.stopFinished()
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testPartialSignalKeepsCallAliveWhileMuted() {
        var tracker = recordingTracker()
        for second in 10..<200 {
            XCTAssertNil(tracker.step(now: at(TimeInterval(second)), signal: .partial, granolaRecording: true))
        }
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
    }

    func testReconnectWithinGraceKeepsOneRecording() {
        var tracker = recordingTracker()
        XCTAssertNil(tracker.step(now: at(100), signal: .none, granolaRecording: true))
        XCTAssertNil(tracker.step(now: at(110), signal: .full, granolaRecording: true))
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
        XCTAssertNil(tracker.step(now: at(125), signal: .none, granolaRecording: true))
        XCTAssertNil(tracker.step(now: at(144), signal: .none, granolaRecording: true))
        XCTAssertEqual(tracker.step(now: at(145), signal: .none, granolaRecording: true), .stopRecording(recordingStartedAt: at(6)))
    }

    func testManualStopMidCallIsRespectedUntilCallEnds() {
        var tracker = recordingTracker()
        XCTAssertNil(tracker.step(now: at(50), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
        // Still in the call: no restart.
        for second in 51..<100 {
            XCTAssertNil(tracker.step(now: at(TimeInterval(second)), signal: .full, granolaRecording: false))
        }
        // Short silence then audio again: still the same call.
        XCTAssertNil(tracker.step(now: at(100), signal: .none, granolaRecording: false))
        XCTAssertNil(tracker.step(now: at(110), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
        // Call really ends.
        XCTAssertNil(tracker.step(now: at(200), signal: .none, granolaRecording: false))
        XCTAssertNil(tracker.step(now: at(220), signal: .none, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .idle)
        // The next call records again.
        XCTAssertNil(tracker.step(now: at(300), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.step(now: at(305), signal: .full, granolaRecording: false), .startRecording)
    }

    func testRecordingStoppedDuringGraceSkipsStopCommand() {
        var tracker = recordingTracker()
        XCTAssertNil(tracker.step(now: at(100), signal: .none, granolaRecording: true))
        XCTAssertNil(tracker.step(now: at(105), signal: .none, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: at(100)))
        XCTAssertNil(tracker.step(now: at(120), signal: .none, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testFailedStartWaitsForCallToEnd() {
        var tracker = makeTracker()
        _ = tracker.step(now: at(0), signal: .full, granolaRecording: false)
        XCTAssertEqual(tracker.step(now: at(5), signal: .full, granolaRecording: false), .startRecording)
        tracker.startFailed()
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
        XCTAssertNil(tracker.step(now: at(60), signal: .full, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
    }

    func testFeedbackIsIgnoredInUnexpectedPhases() {
        var tracker = makeTracker()
        tracker.startSucceeded(at: at(0))
        tracker.stopFinished()
        tracker.startFailed()
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testNoCommandsWhileAwaitingResults() {
        var tracker = makeTracker()
        _ = tracker.step(now: at(0), signal: .full, granolaRecording: false)
        _ = tracker.step(now: at(5), signal: .full, granolaRecording: false)
        XCTAssertNil(tracker.step(now: at(6), signal: .none, granolaRecording: false))
        XCTAssertEqual(tracker.phase, .awaitingStart)
    }
}

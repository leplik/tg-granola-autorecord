import AutorecordCore
import XCTest

final class CallTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func observe(
        _ tracker: inout CallTracker,
        _ seconds: TimeInterval,
        _ signal: CallSignal,
        granola: Bool,
        frontmost: Bool = false
    ) -> [TrackerAction] {
        tracker.step(Observation(now: at(seconds), signal: signal, granolaRecording: granola, granolaFrontmost: frontmost))
    }

    private func makeTracker(startDelay: TimeInterval = 5, endGrace: TimeInterval = 20, granolaStopGrace: TimeInterval = 5) -> CallTracker {
        CallTracker(startDelay: startDelay, endGrace: endGrace, granolaStopGrace: granolaStopGrace)
    }

    /// A tracker that started a recording at t0+6 for a call that began at t0.
    private func recordingTracker(granolaStopGrace: TimeInterval = 5) -> CallTracker {
        var tracker = makeTracker(granolaStopGrace: granolaStopGrace)
        XCTAssertEqual(observe(&tracker, 0, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 5, .full, granola: false), [.startRecording])
        tracker.startSucceeded(at: at(6))
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
        return tracker
    }

    // MARK: Starting

    func testStartsAfterDelayWhenMicAndSpeakerStayOpen() {
        var tracker = makeTracker()
        XCTAssertEqual(observe(&tracker, 0, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 4.9, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 5, .full, granola: false), [.startRecording])
        XCTAssertEqual(tracker.phase, .awaitingStart)
    }

    func testZeroDelayStartsOnFirstObservation() {
        var tracker = makeTracker(startDelay: 0)
        XCTAssertEqual(observe(&tracker, 0, .full, granola: false), [.startRecording])
    }

    func testPartialSignalNeverStartsRecording() {
        var tracker = makeTracker()
        for second in 0..<60 {
            XCTAssertEqual(observe(&tracker, TimeInterval(second), .partial, granola: false), [])
        }
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testBlipShorterThanDelayResetsCountdown() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: false)
        _ = observe(&tracker, 3, .partial, granola: false)
        XCTAssertEqual(tracker.phase, .idle)
        _ = observe(&tracker, 4, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 8, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 9, .full, granola: false), [.startRecording])
    }

    func testDoesNotStartWhenGranolaIsAlreadyRecording() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: true)
        XCTAssertEqual(observe(&tracker, 5, .full, granola: true), [])
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
    }

    func testNeverStopsARecordingItDidNotStart() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: true)
        _ = observe(&tracker, 5, .full, granola: true)
        for second in 6..<120 {
            XCTAssertEqual(observe(&tracker, TimeInterval(second), .none, granola: true), [])
        }
        XCTAssertEqual(tracker.phase, .idle)
    }

    // MARK: Stopping at the end of a call

    func testStopsAfterGraceOnceCallGoesSilent() {
        var tracker = recordingTracker()
        XCTAssertEqual(observe(&tracker, 100, .none, granola: true), [])
        XCTAssertEqual(tracker.phase, .callEnding(since: at(100), recordingStartedAt: at(6)))
        XCTAssertEqual(observe(&tracker, 119, .none, granola: true), [])
        XCTAssertEqual(observe(&tracker, 120, .none, granola: true), [.stopRecording(recordingStartedAt: at(6))])
        XCTAssertEqual(tracker.phase, .awaitingStop(recordingStartedAt: at(6), callOver: true))
        XCTAssertEqual(tracker.ownedRecordingStartedAt, at(6))
        tracker.stopFinished()
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertNil(tracker.ownedRecordingStartedAt)
    }

    func testPartialSignalKeepsCallAliveWhileMuted() {
        var tracker = recordingTracker()
        for second in 10..<200 {
            XCTAssertEqual(observe(&tracker, TimeInterval(second), .partial, granola: true), [])
        }
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
    }

    func testReconnectWithinGraceKeepsOneRecording() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 100, .none, granola: true)
        _ = observe(&tracker, 110, .full, granola: true)
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
        _ = observe(&tracker, 125, .none, granola: true)
        XCTAssertEqual(observe(&tracker, 144, .none, granola: true), [])
        XCTAssertEqual(observe(&tracker, 145, .none, granola: true), [.stopRecording(recordingStartedAt: at(6))])
    }

    // MARK: Granola stopping on its own or by hand

    func testGranolaStoppingMidCallIsReportedAfterGrace() {
        var tracker = recordingTracker()
        XCTAssertEqual(observe(&tracker, 50, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 54, .full, granola: false), [])
        XCTAssertEqual(
            observe(&tracker, 55, .full, granola: false),
            [.recordingStoppedExternally(recordingStartedAt: at(6), likelyByUser: false)]
        )
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
    }

    func testFrontmostGranolaAtStopMeansLikelyByUser() {
        var tracker = recordingTracker(granolaStopGrace: 0)
        XCTAssertEqual(
            observe(&tracker, 50, .full, granola: false, frontmost: true),
            [.recordingStoppedExternally(recordingStartedAt: at(6), likelyByUser: true)]
        )
    }

    func testFrontmostIsTakenFromTheMomentGranolaWentQuiet() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 50, .full, granola: false, frontmost: true)
        XCTAssertEqual(
            observe(&tracker, 55, .full, granola: false, frontmost: false),
            [.recordingStoppedExternally(recordingStartedAt: at(6), likelyByUser: true)]
        )
    }

    func testBriefGranolaDropoutIsIgnored() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 50, .full, granola: false)
        _ = observe(&tracker, 53, .full, granola: false)
        _ = observe(&tracker, 54, .full, granola: true)
        XCTAssertEqual(observe(&tracker, 60, .full, granola: false), [])
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
    }

    func testManualStopIsRespectedUntilCallEnds() {
        var tracker = recordingTracker(granolaStopGrace: 0)
        _ = observe(&tracker, 50, .full, granola: false, frontmost: true)
        for second in 51..<100 {
            XCTAssertEqual(observe(&tracker, TimeInterval(second), .full, granola: false), [])
        }
        _ = observe(&tracker, 100, .none, granola: false)
        _ = observe(&tracker, 110, .full, granola: false)
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
        _ = observe(&tracker, 200, .none, granola: false)
        _ = observe(&tracker, 220, .none, granola: false)
        XCTAssertEqual(tracker.phase, .idle)
        _ = observe(&tracker, 300, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 305, .full, granola: false), [.startRecording])
    }

    func testStopDuringCallEndingIsNotReported() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 100, .none, granola: true)
        _ = observe(&tracker, 105, .none, granola: false)
        XCTAssertEqual(observe(&tracker, 110, .none, granola: false), [])
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: at(100)))
        _ = observe(&tracker, 120, .none, granola: false)
        XCTAssertEqual(tracker.phase, .idle)
    }

    // MARK: User requests and feedback

    func testStopRequestedByUserMidCall() {
        var tracker = recordingTracker()
        XCTAssertEqual(tracker.stopRequestedByUser(), .stopRecording(recordingStartedAt: at(6)))
        XCTAssertEqual(tracker.phase, .awaitingStop(recordingStartedAt: at(6), callOver: false))
        XCTAssertNil(tracker.stopRequestedByUser())
        tracker.stopFinished()
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
        XCTAssertEqual(observe(&tracker, 60, .full, granola: false), [])
    }

    func testStopRequestedWithoutOwnRecordingDoesNothing() {
        var tracker = makeTracker()
        XCTAssertNil(tracker.stopRequestedByUser())
        _ = observe(&tracker, 0, .full, granola: true)
        _ = observe(&tracker, 5, .full, granola: true)
        XCTAssertNil(tracker.stopRequestedByUser())
    }

    func testFailedStartWaitsForCallToEnd() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 5, .full, granola: false), [.startRecording])
        tracker.startFailed()
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil))
        XCTAssertEqual(observe(&tracker, 60, .full, granola: false), [])
    }

    func testFeedbackIsIgnoredInUnexpectedPhases() {
        var tracker = makeTracker()
        tracker.startSucceeded(at: at(0))
        tracker.stopFinished()
        tracker.startFailed()
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testNoActionsWhileAwaitingResults() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: false)
        _ = observe(&tracker, 5, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 6, .none, granola: false), [])
        XCTAssertEqual(tracker.phase, .awaitingStart)
    }

    func testRestoredTrackerOwnsTheRecording() {
        var tracker = CallTracker(startDelay: 5, endGrace: 20, restoredRecordingStartedAt: at(-600))
        XCTAssertEqual(tracker.ownedRecordingStartedAt, at(-600))
        _ = observe(&tracker, 0, .none, granola: true)
        XCTAssertEqual(observe(&tracker, 20, .none, granola: true), [.stopRecording(recordingStartedAt: at(-600))])
    }
}

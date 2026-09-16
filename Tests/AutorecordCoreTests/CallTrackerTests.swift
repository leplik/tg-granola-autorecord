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

    /// Observes once per second over `range`.
    private func observe(
        _ tracker: inout CallTracker,
        _ range: Range<Int>,
        _ signal: CallSignal,
        granola: Bool,
        frontmost: Bool = false
    ) -> [TrackerAction] {
        range.flatMap { observe(&tracker, TimeInterval($0), signal, granola: granola, frontmost: frontmost) }
    }

    private func makeTracker(startDelay: TimeInterval = 5, endGrace: TimeInterval = 20, granolaStopGrace: TimeInterval = 15) -> CallTracker {
        CallTracker(startDelay: startDelay, endGrace: endGrace, granolaStopGrace: granolaStopGrace)
    }

    /// A tracker that started a recording at t0+6 for a call that began at t0.
    private func recordingTracker(granolaStopGrace: TimeInterval = 15) -> CallTracker {
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
        XCTAssertEqual(observe(&tracker, 0..<60, .partial, granola: false), [])
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
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: nil))
    }

    func testNeverStopsARecordingItDidNotStart() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: true)
        _ = observe(&tracker, 5, .full, granola: true)
        XCTAssertEqual(observe(&tracker, 6..<120, .none, granola: true), [])
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
        XCTAssertEqual(observe(&tracker, 10..<200, .partial, granola: true), [])
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

    func testGranolaDroppingTheMicrophoneAfterTheCallStillEndsInAStop() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 100, .none, granola: true)
        XCTAssertEqual(observe(&tracker, 101..<110, .none, granola: false), [])
        XCTAssertEqual(observe(&tracker, 110..<120, .none, granola: true), [])
        XCTAssertEqual(observe(&tracker, 120, .none, granola: true), [.stopRecording(recordingStartedAt: at(6))])
    }

    func testRecordingThatEndedDuringCallEndingStillGetsAStopAttempt() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 100, .none, granola: true)
        XCTAssertEqual(observe(&tracker, 101..<120, .none, granola: false), [])
        XCTAssertEqual(observe(&tracker, 120, .none, granola: false), [.stopRecording(recordingStartedAt: at(6))])
    }

    // MARK: Granola stopping mid-call

    func testGranolaStoppingMidCallIsReportedAfterGrace() {
        var tracker = recordingTracker()
        XCTAssertEqual(observe(&tracker, 50..<65, .full, granola: false), [])
        XCTAssertEqual(
            observe(&tracker, 65, .full, granola: false),
            [.recordingStoppedExternally(recordingStartedAt: at(6), likelyByUser: false)]
        )
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: .lostRecording(startedAt: at(6))))
    }

    func testShortMidCallDropoutIsIgnored() {
        var tracker = recordingTracker()
        XCTAssertEqual(observe(&tracker, 50..<60, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 60..<100, .full, granola: true), [])
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
    }

    func testRecordingResumedAfterAnExternalStopIsTrackedAgain() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 50..<66, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 90, .full, granola: true), [])
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(6)))
        _ = observe(&tracker, 200, .none, granola: true)
        XCTAssertEqual(observe(&tracker, 220, .none, granola: true), [.stopRecording(recordingStartedAt: at(6))])
    }

    func testFrontmostGranolaAtStopMeansLikelyByUser() {
        var tracker = recordingTracker(granolaStopGrace: 0)
        XCTAssertEqual(
            observe(&tracker, 50, .full, granola: false, frontmost: true),
            [.recordingStoppedExternally(recordingStartedAt: at(6), likelyByUser: true)]
        )
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: nil))
    }

    func testFrontmostIsTakenFromTheMomentGranolaWentQuiet() {
        var tracker = recordingTracker()
        _ = observe(&tracker, 50, .full, granola: false, frontmost: true)
        XCTAssertEqual(
            observe(&tracker, 51..<66, .full, granola: false, frontmost: false),
            [.recordingStoppedExternally(recordingStartedAt: at(6), likelyByUser: true)]
        )
    }

    func testRecordingRestartedByHandIsNotClaimed() {
        var tracker = recordingTracker(granolaStopGrace: 0)
        _ = observe(&tracker, 50, .full, granola: false, frontmost: true)
        XCTAssertEqual(observe(&tracker, 51..<100, .full, granola: true), [])
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: nil))
        _ = observe(&tracker, 100..<130, .none, granola: true)
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testManualStopIsRespectedUntilCallEnds() {
        var tracker = recordingTracker(granolaStopGrace: 0)
        _ = observe(&tracker, 50, .full, granola: false, frontmost: true)
        XCTAssertEqual(observe(&tracker, 51..<100, .full, granola: false), [])
        _ = observe(&tracker, 100, .none, granola: false)
        _ = observe(&tracker, 110, .full, granola: false)
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: nil))
        _ = observe(&tracker, 200, .none, granola: false)
        _ = observe(&tracker, 220, .none, granola: false)
        XCTAssertEqual(tracker.phase, .idle)
        _ = observe(&tracker, 300, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 305, .full, granola: false), [.startRecording])
    }

    // MARK: Late starts

    private func timedOutTracker() -> CallTracker {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 5, .full, granola: false), [.startRecording])
        tracker.startFailed(at: at(50), mayStillStart: true)
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: .pendingStart(since: at(50))))
        return tracker
    }

    func testLateStartDuringTheCallIsClaimed() {
        var tracker = timedOutTracker()
        XCTAssertEqual(observe(&tracker, 51..<80, .full, granola: false), [])
        XCTAssertEqual(observe(&tracker, 80, .full, granola: true), [.recordingStartedLate])
        XCTAssertEqual(tracker.phase, .recording(startedAt: at(80)))
    }

    func testLateStartAfterTheCallEndedIsClaimedAndStopped() {
        var tracker = timedOutTracker()
        _ = observe(&tracker, 51..<60, .full, granola: false)
        XCTAssertEqual(observe(&tracker, 60..<150, .none, granola: false), [])
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: at(60), claim: .pendingStart(since: at(50))))
        XCTAssertEqual(observe(&tracker, 150, .none, granola: true), [.recordingStartedLate])
        XCTAssertEqual(observe(&tracker, 151..<170, .none, granola: true), [])
        XCTAssertEqual(observe(&tracker, 171, .none, granola: true), [.stopRecording(recordingStartedAt: at(150))])
    }

    func testLateStartClaimExpires() {
        var tracker = timedOutTracker()
        _ = observe(&tracker, 51..<60, .full, granola: false)
        _ = observe(&tracker, 60..<231, .none, granola: false)
        XCTAssertEqual(tracker.phase, .idle)
        XCTAssertEqual(observe(&tracker, 231..<300, .none, granola: true), [])
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testStartThatFailedForGoodClaimsNothing() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: false)
        _ = observe(&tracker, 5, .full, granola: false)
        tracker.startFailed(at: at(6), mayStillStart: false)
        XCTAssertEqual(observe(&tracker, 7..<60, .full, granola: true), [])
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: nil))
    }

    // MARK: User requests and feedback

    func testStopRequestedByUserMidCall() {
        var tracker = recordingTracker()
        XCTAssertEqual(tracker.stopRequestedByUser(), .stopRecording(recordingStartedAt: at(6)))
        XCTAssertEqual(tracker.phase, .awaitingStop(recordingStartedAt: at(6), callOver: false))
        XCTAssertNil(tracker.stopRequestedByUser())
        tracker.stopFinished()
        XCTAssertEqual(tracker.phase, .notOurs(quietSince: nil, claim: nil))
        XCTAssertEqual(observe(&tracker, 60, .full, granola: false), [])
    }

    func testStopRequestedWithoutOwnRecordingDoesNothing() {
        var tracker = makeTracker()
        XCTAssertNil(tracker.stopRequestedByUser())
        _ = observe(&tracker, 0, .full, granola: true)
        _ = observe(&tracker, 5, .full, granola: true)
        XCTAssertNil(tracker.stopRequestedByUser())
    }

    func testHoldOffUntilCallEndsPreventsAStart() {
        var tracker = makeTracker()
        _ = observe(&tracker, 0, .full, granola: false)
        tracker.holdOffUntilCallEnds()
        XCTAssertEqual(observe(&tracker, 1..<60, .full, granola: false), [])
        _ = observe(&tracker, 60..<81, .none, granola: false)
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testFeedbackIsIgnoredInUnexpectedPhases() {
        var tracker = makeTracker()
        tracker.startSucceeded(at: at(0))
        tracker.stopFinished()
        tracker.startFailed(at: at(0), mayStillStart: true)
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

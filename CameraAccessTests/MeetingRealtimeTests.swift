import XCTest
@testable import CameraAccess

final class MeetingRealtimeTests: XCTestCase {
    func testShortUndelimitedSpeechIsAnalyzedAfterPause() {
        XCTAssertTrue(MeetingTranscriptionService.shouldAnalyze(
            pending: "EBITDA가 뭐죠", previous: "", quietTime: 1.1, elapsed: 1.1))
    }

    func testContinuousSpeechDoesNotWaitForever() {
        XCTAssertTrue(MeetingTranscriptionService.shouldAnalyze(
            pending: "지금 계속 설명하고 있는데", previous: "", quietTime: 0.1, elapsed: 4.1))
    }

    func testUnchangedSnapshotIsNotResubmitted() {
        XCTAssertFalse(MeetingTranscriptionService.shouldAnalyze(
            pending: "EBITDA", previous: "EBITDA", quietTime: 10, elapsed: 10))
    }

    func testRevisionWaitsForStability() {
        XCTAssertFalse(MeetingTranscriptionService.shouldAnalyze(
            pending: "EBITDA", previous: "에비", quietTime: 0.1, elapsed: 0.5))
        XCTAssertTrue(MeetingTranscriptionService.shouldAnalyze(
            pending: "EBITDA", previous: "에비", quietTime: 1, elapsed: 1.5))
    }

    func testSceneComparisonSkipsSmallNoiseButAcceptsChange() {
        XCTAssertFalse(VisualAssistService.sceneChanged([100, 100], [102, 98]))
        XCTAssertTrue(VisualAssistService.sceneChanged([100, 100], [120, 120]))
        XCTAssertTrue(VisualAssistService.sceneChanged([], [120]))
    }
}

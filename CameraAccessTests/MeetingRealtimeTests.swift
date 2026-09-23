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

    // MARK: - 같은 화면 판정(16×16 흑백 썸네일)

    private func grid(_ value: (Int, Int) -> Int) -> [UInt8] {
        var cells: [UInt8] = []
        for y in 0..<16 {
            for x in 0..<16 {
                cells.append(UInt8(clamping: value(x, y)))
            }
        }
        return cells
    }

    /// 왼쪽은 어둡고 오른쪽은 밝은 슬라이드에 잔무늬가 있는 화면.
    private func slideValue(_ x: Int, _ y: Int) -> Int {
        (x < 8 ? 40 : 200) + ((x * 13 + y * 7) % 20)
    }

    func testSceneSmallNoiseIsSameScene() {
        let before = grid(slideValue)
        let after = grid { x, y in slideValue(x, y) + ((x + y) % 7) - 3 }
        XCTAssertFalse(VisualAssistService.sceneChanged(before, after))
    }

    func testSceneBrightnessShiftIsSameScene() {
        let before = grid(slideValue)
        let after = grid { x, y in slideValue(x, y) + 15 }
        XCTAssertEqual(VisualAssistService.sceneDifference(before, after), 0, accuracy: 0.001)
        XCTAssertFalse(VisualAssistService.sceneChanged(before, after))
    }

    func testSceneOneCellHeadMovementIsSameScene() {
        let before = grid(slideValue)
        let after = grid { x, y in slideValue(max(x - 1, 0), y) }
        XCTAssertEqual(VisualAssistService.sceneDifference(before, after), 0, accuracy: 0.001)
        XCTAssertFalse(VisualAssistService.sceneChanged(before, after))
    }

    func testSceneContentChangeIsDetected() {
        let before = grid(slideValue)
        let after = grid { x, y in (x < 8 ? 200 : 40) + ((x * 13 + y * 7) % 20) }
        XCTAssertGreaterThan(VisualAssistService.sceneDifference(before, after), 100)
        XCTAssertTrue(VisualAssistService.sceneChanged(before, after))
    }

    func testSceneSizeMismatchCountsAsChange() {
        let before = grid(slideValue)
        XCTAssertTrue(VisualAssistService.sceneChanged([], [120]))
        XCTAssertTrue(VisualAssistService.sceneChanged(before, Array(before.prefix(10))))
    }
}

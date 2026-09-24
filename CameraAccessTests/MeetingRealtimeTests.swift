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

    // MARK: - 마이크 선택과 입력 품질

    func testMicModeDefaultsToPhone() {
        XCTAssertEqual(MeetingMicMode.resolve(stored: nil), .phone)
        XCTAssertEqual(MeetingMicMode.resolve(stored: "unknown"), .phone)
        XCTAssertEqual(MeetingMicMode.resolve(stored: "headset"), .headset)
    }

    /// 귓속말이 폰 스피커로 나올 때만 에코 제거를 켠다. 안경(A2DP)으로 나가면 끈다.
    func testEchoCancellationOnlyForPhoneOutputs() {
        XCTAssertTrue(MeetingTranscriptionService.needsEchoCancellation(outputs: [.builtInSpeaker]))
        XCTAssertTrue(MeetingTranscriptionService.needsEchoCancellation(outputs: [.builtInReceiver]))
        XCTAssertFalse(MeetingTranscriptionService.needsEchoCancellation(outputs: [.bluetoothA2DP]))
        XCTAssertFalse(MeetingTranscriptionService.needsEchoCancellation(outputs: []))
    }

    func testRmsDecibels() {
        XCTAssertEqual(MeetingInputMeter.rmsDecibels([Float](repeating: 0, count: 64)), MeetingInputMeter.floorDb)
        let sine = (0..<4800).map { Float(sin(Double($0) * 2 * .pi / 48)) }
        XCTAssertEqual(MeetingInputMeter.rmsDecibels(sine), -3.01, accuracy: 0.05)
        let quiet = sine.map { $0 * 0.001 }
        XCTAssertEqual(MeetingInputMeter.rmsDecibels(quiet), -63.01, accuracy: 0.05)
    }

    func testQuietNeedsThirtySecondsOfSilence() {
        let silent = MeetingInputWindow(buffers: 100, averageDb: -70, peakDb: -60, speechRatio: 0)
        let talking = MeetingInputWindow(buffers: 100, averageDb: -40, peakDb: -25, speechRatio: 0.5)
        XCTAssertFalse(MeetingInputMeter.isQuiet([silent, silent]))
        XCTAssertTrue(MeetingInputMeter.isQuiet([silent, silent, silent]))
        XCTAssertFalse(MeetingInputMeter.isQuiet([silent, talking, silent]))
        XCTAssertTrue(MeetingInputMeter.isQuiet([talking, silent, silent, silent]))
    }
}

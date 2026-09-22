import XCTest
@testable import CameraAccess

final class MeetingSegmentationTests: XCTestCase {
    func testDeltaEmitsUpToLastDelimiter() throws {
        let delta = try XCTUnwrap(
            MeetingTranscriptionService.nextEmitDelta(
                pending: "이번 분기 EBITDA가 개선됐습니다. 다음 안건은",
                emitted: ""
            )
        )

        XCTAssertEqual(delta.emit, "이번 분기 EBITDA가 개선됐습니다.")
        XCTAssertEqual(delta.newEmitted, "이번 분기 EBITDA가 개선됐습니다.")
    }

    func testDeltaWaitsWhenNoDelimiterAndShort() {
        XCTAssertNil(
            MeetingTranscriptionService.nextEmitDelta(
                pending: "이번 분기 EBITDA 마진 이야기를",
                emitted: ""
            )
        )
    }

    func testDeltaHardFlushesLongTailWithoutDelimiter() throws {
        let longTail = String(repeating: "가", count: MeetingTranscriptionService.hardFlushLength + 3)
        let delta = try XCTUnwrap(
            MeetingTranscriptionService.nextEmitDelta(pending: longTail, emitted: "")
        )

        XCTAssertEqual(delta.emit, longTail)
        XCTAssertEqual(delta.newEmitted, longTail)
    }

    func testDeltaHandlesRecognitionRevision() throws {
        let delta = try XCTUnwrap(
            MeetingTranscriptionService.nextEmitDelta(
                pending: "이번 분기 EBITDA 개선됐습니다.",
                emitted: "이번 분기 개선"
            )
        )

        XCTAssertEqual(delta.emit, "EBITDA 개선됐습니다.")
        XCTAssertEqual(delta.newEmitted, "이번 분기 EBITDA 개선됐습니다.")
    }

    func testDeltaIgnoresTooShortEmit() {
        XCTAssertNil(
            MeetingTranscriptionService.nextEmitDelta(pending: "네.", emitted: "")
        )
    }

    func testCommonPrefixLength() {
        XCTAssertEqual(MeetingTranscriptionService.commonPrefixLength("안녕하세요", "안녕히"), 2)
        XCTAssertEqual(MeetingTranscriptionService.commonPrefixLength("abc", "abc"), 3)
        XCTAssertEqual(MeetingTranscriptionService.commonPrefixLength("", "abc"), 0)
    }
}

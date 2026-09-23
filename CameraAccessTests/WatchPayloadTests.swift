import XCTest
@testable import CameraAccess

final class WatchPayloadTests: XCTestCase {
    func testPayloadCarriesAllFields() {
        let payload = WatchMeetingStatus.payload(
            state: "listening",
            route: "Oakley Meta",
            startedAt: Date(timeIntervalSince1970: 1_000),
            latest: "EBITDA 얘기입니다",
            recent: ["첫 문장", "EBITDA 얘기입니다"],
            whisperCount: 3,
            error: "",
            quotaPaused: true
        )

        XCTAssertEqual(payload[WatchMeetingStatus.state] as? String, "listening")
        XCTAssertEqual(payload[WatchMeetingStatus.route] as? String, "Oakley Meta")
        XCTAssertEqual(payload[WatchMeetingStatus.startedAt] as? TimeInterval, 1_000)
        XCTAssertEqual(payload[WatchMeetingStatus.latest] as? String, "EBITDA 얘기입니다")
        XCTAssertEqual((payload[WatchMeetingStatus.recent] as? [String])?.count, 2)
        XCTAssertEqual(payload[WatchMeetingStatus.whisperCount] as? Int, 3)
        XCTAssertEqual(payload[WatchMeetingStatus.error] as? String, "")
        XCTAssertEqual(payload[WatchMeetingStatus.quotaPaused] as? Bool, true)
    }

    func testPayloadOmitsStartedAtWhenMissing() {
        let payload = WatchMeetingStatus.payload(
            state: "idle", route: "-", startedAt: nil, latest: "",
            recent: [], whisperCount: 0, error: "", quotaPaused: false
        )

        XCTAssertNil(payload[WatchMeetingStatus.startedAt])
    }
}

import XCTest
@testable import CameraAccess

@MainActor
final class TTSPlaybackStateTests: XCTestCase {
    func testQueuedAndSpeakingAreActiveOnlyForMatchingRequest() {
        let requestID = UUID()
        let otherRequestID = UUID()

        XCTAssertTrue(
            TTSService.PlaybackState.queued(requestID)
                .isActive(requestID: requestID)
        )
        XCTAssertTrue(
            TTSService.PlaybackState.speaking(requestID)
                .isActive(requestID: requestID)
        )
        XCTAssertFalse(
            TTSService.PlaybackState.queued(requestID)
                .isActive(requestID: otherRequestID)
        )
        XCTAssertFalse(
            TTSService.PlaybackState.speaking(requestID)
                .isActive(requestID: otherRequestID)
        )
    }

    func testTerminalStatesAreNotActive() {
        let requestID = UUID()

        XCTAssertFalse(
            TTSService.PlaybackState.idle
                .isActive(requestID: requestID)
        )
        XCTAssertFalse(
            TTSService.PlaybackState.failed(requestID)
                .isActive(requestID: requestID)
        )
    }

    func testRequestIdentityIsPreservedByNonIdleStates() {
        let requestID = UUID()

        XCTAssertNil(TTSService.PlaybackState.idle.requestID)
        XCTAssertEqual(
            TTSService.PlaybackState.queued(requestID).requestID,
            requestID
        )
        XCTAssertEqual(
            TTSService.PlaybackState.speaking(requestID).requestID,
            requestID
        )
        XCTAssertEqual(
            TTSService.PlaybackState.failed(requestID).requestID,
            requestID
        )
    }
}

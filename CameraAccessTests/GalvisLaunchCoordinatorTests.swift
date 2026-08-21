import XCTest
@testable import CameraAccess

@MainActor
final class GalvisLaunchCoordinatorTests: XCTestCase {
    func testVoiceRequestWaitsForAppReadinessAndPresentsOnlyVoice() {
        let coordinator = GalvisLaunchCoordinator()

        coordinator.requestOpenClawSession()

        XCTAssertFalse(coordinator.isOpenClawSessionPresented)
        XCTAssertFalse(coordinator.isOpenClawChatPresented)

        coordinator.markAppReady()

        XCTAssertTrue(coordinator.isOpenClawSessionPresented)
        XCTAssertFalse(coordinator.isOpenClawChatPresented)
    }

    func testChatRequestPresentsOnlyChatAndPreservesSelectedMessage() {
        let coordinator = GalvisLaunchCoordinator()
        let messageID = UUID()
        coordinator.markAppReady()

        coordinator.requestOpenClawChat(messageID: messageID)

        XCTAssertFalse(coordinator.isOpenClawSessionPresented)
        XCTAssertTrue(coordinator.isOpenClawChatPresented)
        XCTAssertEqual(coordinator.selectedOpenClawMessageID, messageID)
    }

    func testOverlappingRequestsPresentOneCoverAtATime() {
        let coordinator = GalvisLaunchCoordinator()

        coordinator.requestOpenClawChat()
        coordinator.requestOpenClawSession()
        coordinator.markAppReady()

        XCTAssertTrue(coordinator.isOpenClawSessionPresented)
        XCTAssertFalse(coordinator.isOpenClawChatPresented)

        coordinator.dismissOpenClawSession()

        XCTAssertFalse(coordinator.isOpenClawSessionPresented)
        XCTAssertTrue(coordinator.isOpenClawChatPresented)
    }

    func testDismissedVoiceSessionCanBeRequestedAgain() {
        let coordinator = GalvisLaunchCoordinator()
        coordinator.markAppReady()
        coordinator.requestOpenClawSession()

        coordinator.dismissOpenClawSession()
        coordinator.requestOpenClawSession()

        XCTAssertTrue(coordinator.isOpenClawSessionPresented)
        XCTAssertFalse(coordinator.isOpenClawChatPresented)
    }
}

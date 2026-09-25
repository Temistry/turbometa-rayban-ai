import XCTest

@testable import CameraAccess

final class OpenClawChatHistoryStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testMessagesPersistInOrderWithoutImageBytes() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("history.json")
        let store = OpenClawChatHistoryStore(
            storageURL: storageURL,
            maximumMessages: 10
        )
        let messages = [
            OpenClawChatMessage(
                role: "user",
                text: "사진을 확인해 줘",
                hadImage: true
            ),
            OpenClawChatMessage(
                role: "assistant",
                text: "확인했습니다.",
                eventIdentity: "run-1:2"
            )
        ]

        store.save(messages)
        let loaded = store.load()

        XCTAssertEqual(loaded.map(\.role), ["user", "assistant"])
        XCTAssertEqual(loaded.map(\.text), ["사진을 확인해 줘", "확인했습니다."])
        XCTAssertTrue(loaded[0].hadImage)
        XCTAssertNil(loaded[0].image)
        XCTAssertEqual(loaded[1].eventIdentity, "run-1:2")
    }

    func testRetentionKeepsNewestMessages() {
        let store = OpenClawChatHistoryStore(
            storageURL: temporaryDirectory.appendingPathComponent("history.json"),
            maximumMessages: 2
        )
        let messages = ["첫째", "둘째", "셋째"].map {
            OpenClawChatMessage(role: "user", text: $0)
        }

        let saved = store.save(messages)

        XCTAssertEqual(saved.map(\.text), ["둘째", "셋째"])
        XCTAssertEqual(store.load().map(\.text), ["둘째", "셋째"])
    }

    func testCorruptFileReturnsEmptyHistory() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("history.json")
        try Data("not-json".utf8).write(to: storageURL)
        let store = OpenClawChatHistoryStore(storageURL: storageURL)

        XCTAssertTrue(store.load().isEmpty)
    }

    func testDeleteAllRemovesPersistedHistory() {
        let store = OpenClawChatHistoryStore(
            storageURL: temporaryDirectory.appendingPathComponent("history.json")
        )
        store.save([OpenClawChatMessage(role: "user", text: "질문")])

        store.deleteAll()

        XCTAssertTrue(store.load().isEmpty)
    }

    func testFinalEventIdentityRequiresRunAndSequence() {
        XCTAssertEqual(
            OpenClawNodeService.finalEventIdentity(
                runID: "run-1",
                sequence: 3
            ),
            "run-1:3"
        )
        XCTAssertNil(
            OpenClawNodeService.finalEventIdentity(
                runID: nil,
                sequence: 3
            )
        )
        XCTAssertNil(
            OpenClawNodeService.finalEventIdentity(
                runID: "run-1",
                sequence: nil
            )
        )
    }
}

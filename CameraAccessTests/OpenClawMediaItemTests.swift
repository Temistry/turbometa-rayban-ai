import XCTest
@testable import CameraAccess

final class OpenClawMediaItemTests: XCTestCase {
    private func snapshot(
        prompt: String = "original prompt",
        media: OpenClawCaptureModeMedia = .photo
    ) -> OpenClawCaptureModeExecutionSnapshot {
        OpenClawCaptureModeExecutionSnapshot(
            id: UUID(),
            name: "Test Mode",
            prompt: prompt,
            media: media
        )
    }

    func testFilenamesAndSnapshotAreStored() {
        let id = UUID()
        let modeSnapshot = snapshot()
        let requestID = UUID()
        let item = OpenClawMediaItem(
            id: id,
            kind: .photo,
            originalExtension: "jpg",
            byteSize: 1234,
            modeSnapshot: modeSnapshot,
            requestID: requestID
        )

        XCTAssertEqual(item.originalRelativePath, "\(id.uuidString).jpg")
        XCTAssertEqual(item.thumbnailRelativePath, "\(id.uuidString).jpg")
        XCTAssertEqual(item.modeSnapshot, modeSnapshot)
        XCTAssertEqual(item.requestID, requestID)
    }

    func testProvidedRelativePathsCannotEscapeRepositoryDirectory() {
        let item = OpenClawMediaItem(
            kind: .photo,
            originalExtension: "jpg",
            originalRelativePath: "../../outside.jpg",
            thumbnailRelativePath: "nested/thumb.jpg",
            byteSize: 10,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        XCTAssertEqual(item.originalRelativePath, "outside.jpg")
        XCTAssertEqual(item.thumbnailRelativePath, "thumb.jpg")
    }

    func testDefaultStatusesAreIndependent() {
        let item = OpenClawMediaItem(
            kind: .photo,
            originalExtension: "jpg",
            byteSize: 1,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        XCTAssertEqual(item.localStatus, .staged)
        XCTAssertEqual(item.photosStatus, .notRequested)
        XCTAssertEqual(item.analysisStatus, .notRequested)
        XCTAssertEqual(item.deliveryStatus, .notAttempted)
        XCTAssertEqual(item.retryAttempt, 0)
    }

    func testCopyHelpersPreserveSensitiveExecutionSnapshot() {
        let original = OpenClawMediaItem(
            kind: .video,
            originalExtension: "mp4",
            byteSize: 42,
            modeSnapshot: snapshot(prompt: "frozen retry prompt", media: .video),
            requestID: UUID(),
            photosStatus: .failed,
            analysisStatus: .pending
        )
        let assistantID = UUID()

        let updated = original
            .withDeliveryStatus(.ambiguous)
            .withRetryAttempt(2)
            .withLinkedMessages(assistantMessageID: assistantID)

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.modeSnapshot, original.modeSnapshot)
        XCTAssertEqual(updated.modeSnapshot.prompt, "frozen retry prompt")
        XCTAssertEqual(updated.photosStatus, .failed)
        XCTAssertEqual(updated.analysisStatus, .pending)
        XCTAssertEqual(updated.deliveryStatus, .ambiguous)
        XCTAssertEqual(updated.retryAttempt, 2)
        XCTAssertEqual(updated.linkedAssistantMessageID, assistantID)
    }

    func testNegativeRetryAttemptIsClamped() {
        let item = OpenClawMediaItem(
            kind: .photo,
            originalExtension: "jpg",
            byteSize: 1,
            modeSnapshot: snapshot(),
            requestID: UUID(),
            retryAttempt: -10
        )

        XCTAssertEqual(item.retryAttempt, 0)
        XCTAssertEqual(item.withRetryAttempt(-1).retryAttempt, 0)
    }

    func testRoundTripJSONCodingPreservesRetryPromptAndLocation() throws {
        let location = OpenClawCaptureLocationSnapshot(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 42,
            horizontalAccuracy: 12,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let original = OpenClawMediaItem(
            kind: .video,
            originalExtension: "mp4",
            byteSize: 42,
            width: 1920,
            height: 1080,
            durationSeconds: 8.5,
            location: location,
            modeSnapshot: snapshot(prompt: "protected exact prompt", media: .video),
            requestID: UUID(),
            deliveryStatus: .delivered
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OpenClawMediaItem.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.modeSnapshot.prompt, "protected exact prompt")
        XCTAssertEqual(decoded.location, location)
    }

    func testLegacyJSONWithoutLocationStillDecodes() throws {
        let original = OpenClawMediaItem(
            kind: .photo,
            originalExtension: "jpg",
            byteSize: 99,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "location")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OpenClawMediaItem.self, from: legacyData)

        XCTAssertNil(decoded.location)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.modeSnapshot, original.modeSnapshot)
    }

    func testCopyHelpersPreserveLocationSnapshot() {
        let location = OpenClawCaptureLocationSnapshot(
            latitude: 1,
            longitude: -2,
            altitude: nil,
            horizontalAccuracy: 25,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let original = OpenClawMediaItem(
            kind: .photo,
            originalExtension: "jpg",
            byteSize: 1,
            location: location,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        XCTAssertEqual(original.withPhotosStatus(.saved).location, location)
        XCTAssertEqual(original.withAnalysisStatus(.completed).location, location)
    }
}

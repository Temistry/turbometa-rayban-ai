/*
 * Quick Vision lifecycle and privacy regression coverage.
 */

import Foundation
import XCTest

@testable import CameraAccess

final class QuickVisionRecordTests: XCTestCase {
    func testLegacyRecordDecodesAsSuccessfulRecord() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyRecord: [String: Any] = [
            "id": id.uuidString,
            "timestamp": timestamp.timeIntervalSinceReferenceDate,
            "mode": QuickVisionMode.standard.rawValue,
            "prompt": "장면을 설명해줘",
            "result": "책상 위에 컵이 있습니다"
        ]
        let data = try JSONSerialization.data(withJSONObject: [legacyRecord])

        let records = try JSONDecoder().decode([QuickVisionRecord].self, from: data)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, id)
        XCTAssertEqual(records[0].status, .succeeded)
        XCTAssertNil(records[0].errorCode)
        XCTAssertNil(records[0].errorMessage)
        XCTAssertEqual(records[0].captureSource, "none")
        XCTAssertEqual(records[0].metadata, [:])
    }

    func testLifecycleFieldsRoundTripWithoutThumbnail() throws {
        let record = QuickVisionRecord(
            mode: .standard,
            prompt: "손가락이 가리키는 것을 설명해줘",
            status: .failed,
            errorCode: "stream_not_ready",
            errorMessage: "인식에 실패했습니다. 다시 시도하세요",
            metadata: ["source": "app", "model": "gemini-test"]
        )

        let decoded = try JSONDecoder().decode(
            QuickVisionRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.errorCode, "stream_not_ready")
        XCTAssertEqual(decoded.errorMessage, "인식에 실패했습니다. 다시 시도하세요")
        XCTAssertEqual(decoded.captureSource, "none")
        XCTAssertNil(decoded.thumbnailData)
        XCTAssertEqual(decoded.metadata["model"], "gemini-test")
    }

    func testQuickVisionKnowledgeEventRedactsMediaAndCredentials() throws {
        let rawKey = "AIza" + String(repeating: "A", count: 36)
        let rawMedia = String(repeating: "A", count: 300)
        let event = KnowledgeLogEvent(
            source: .quickVision,
            question: "apiKey: \(rawKey)",
            answer: "data:image/jpeg;base64,\(rawMedia)",
            model: "gemini-test",
            tags: ["퀵비전", rawKey],
            metadata: ["image": rawMedia, "token": rawKey]
        )
        let serialized = String(data: try JSONEncoder().encode(event), encoding: .utf8) ?? ""

        XCTAssertFalse(serialized.contains(rawKey))
        XCTAssertFalse(serialized.contains(rawMedia))
        XCTAssertFalse(serialized.contains("data:image/jpeg;base64"))
    }

    func testStandardPromptRequiresFingerFirstSceneFallbackAndTranslation() {
        let prompt = QuickVisionModeManager.shared.getPrompt(for: .standard)

        XCTAssertTrue(prompt.contains("손가락"))
        XCTAssertTrue(prompt.contains("추측하지 말고"))
        XCTAssertTrue(prompt.contains("한국어 이외의 글자"))
        XCTAssertTrue(prompt.contains("번역"))
    }
}

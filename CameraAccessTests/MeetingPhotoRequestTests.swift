import XCTest
@testable import CameraAccess

final class MeetingPhotoRequestTests: XCTestCase {
    func testSilentPhotoRequestPreservesOriginalBytes() throws {
        let original = Data([0xff, 0xd8, 0x00, 0x12, 0x34, 0xff, 0xd9])
        let body = MeetingGeminiService.photoRequestBody(jpegData: original, recentContext: "")
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let contents = try XCTUnwrap(decoded["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let attachment = try XCTUnwrap(parts.last?["inline_data"] as? [String: String])
        XCTAssertEqual(attachment["mime_type"], "image/jpeg")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(attachment["data"])), original)
        XCTAssertFalse(try XCTUnwrap(parts.first?["text"] as? String).isEmpty)
    }

    func testBlockedOrEmptyPhotoResponseDoesNotBecomeSpeech() {
        XCTAssertNil(MeetingGeminiService.parseText(["promptFeedback": ["blockReason": "SAFETY"]]))
        XCTAssertNil(MeetingGeminiService.parseText([
            "candidates": [["content": ["parts": [["text": "  \n"]]]]]
        ]))
    }
}

/*
 * Gemini Live raw WebSocket schema regression coverage.
 */

import Foundation
import XCTest

@testable import CameraAccess

final class GeminiLiveMessageBuilderTests: XCTestCase {
    func testSetupUsesCamelCaseGenerationConfigSchema() throws {
        let message = GeminiLiveMessageBuilder.setup(
            model: GeminiModelCatalog.live,
            systemInstruction: "Translate spoken Korean into English.",
            voiceName: "Aoede",
            audioOutputEnabled: true
        )

        let setup = try dictionary(message["setup"])
        XCTAssertEqual(setup["model"] as? String, "models/\(GeminiModelCatalog.live)")
        XCTAssertNil(setup["responseModalities"])
        XCTAssertNil(setup["speechConfig"])

        let generationConfig = try dictionary(setup["generationConfig"])
        XCTAssertEqual(generationConfig["responseModalities"] as? [String], ["AUDIO"])

        let speechConfig = try dictionary(generationConfig["speechConfig"])
        let voiceConfig = try dictionary(speechConfig["voiceConfig"])
        let prebuiltVoiceConfig = try dictionary(voiceConfig["prebuiltVoiceConfig"])
        XCTAssertEqual(prebuiltVoiceConfig["voiceName"] as? String, "Aoede")

        XCTAssertNotNil(setup["systemInstruction"])
        XCTAssertNotNil(setup["inputAudioTranscription"])
        XCTAssertNotNil(setup["outputAudioTranscription"])

        let wireText = try serializedText(message)
        [
            "generation_config",
            "response_modalities",
            "speech_config",
            "voice_config",
            "prebuilt_voice_config",
            "voice_name",
            "system_instruction",
        ].forEach { legacyKey in
            XCTAssertFalse(wireText.contains(legacyKey), "레거시 키가 포함됨: \(legacyKey)")
        }
    }


    func testRealtimeInputUsesMediaChunksArray() throws {
        let sourceData = Data([0x00, 0x01, 0x02, 0x03])
        let message = GeminiLiveMessageBuilder.realtimeInput(
            data: sourceData,
            mimeType: "audio/pcm;rate=16000"
        )

        let realtimeInput = try dictionary(message["realtimeInput"])
        let mediaChunks = try XCTUnwrap(realtimeInput["mediaChunks"] as? [[String: Any]])
        XCTAssertEqual(mediaChunks.count, 1)
        XCTAssertEqual(mediaChunks[0]["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(mediaChunks[0]["data"] as? String, sourceData.base64EncodedString())
        XCTAssertNil(realtimeInput["audio"])
        XCTAssertNil(realtimeInput["video"])

        let wireText = try serializedText(message)
        XCTAssertFalse(wireText.contains("realtime_input"))
        XCTAssertFalse(wireText.contains("media_chunks"))
        XCTAssertFalse(wireText.contains("mime_type"))
    }

    func testNormalizesOnlyEmptyOrRetiredLiveModel() {
        XCTAssertEqual(APIProviderManager.normalizedLiveAIModel(nil), GeminiModelCatalog.live)
        XCTAssertEqual(APIProviderManager.normalizedLiveAIModel("  "), GeminiModelCatalog.live)
        XCTAssertEqual(
            APIProviderManager.normalizedLiveAIModel("gemini-2.0-flash-exp"),
            GeminiModelCatalog.live
        )
        XCTAssertEqual(
            APIProviderManager.normalizedLiveAIModel("gemini-custom-live"),
            "gemini-custom-live"
        )
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func serializedText(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

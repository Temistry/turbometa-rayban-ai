/*
 * Google Gemini 이미지 이해 API 설정
 *
 * 일반 실행 경로는 Google Gemini로 고정한다. 실제 인증값은 APIKeyManager를 통해
 * iOS Keychain에서만 읽으며 URL, 콘솔, UserDefaults 또는 파일에 기록하지 않는다.
 */

import Foundation

struct VisionAPIConfig {
    static var apiKey: String {
        APIKeyManager.shared.getGoogleAPIKey() ?? ""
    }

    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    static let model = GeminiModelCatalog.quickVision
    static let provider: APIProvider = .google

    static func generateContentURL(model: String = model) -> URL? {
        URL(string: "\(baseURL)/models/\(model):generateContent")
    }

    static func headers(with apiKey: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "x-goog-api-key": apiKey
        ]
    }
}

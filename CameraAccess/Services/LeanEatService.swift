/* Google Gemini 기반 음식 영양 분석 서비스 */

import Foundation
import UIKit

final class LeanEatService {
    private let visionService: QuickVisionService

    init(apiKey: String) {
        visionService = QuickVisionService(
            apiKey: apiKey,
            baseURL: VisionAPIConfig.baseURL,
            model: GeminiModelCatalog.quickVision
        )
    }

    func analyzeFood(_ image: UIImage) async throws -> FoodNutritionResponse {
        let prompt = """
        사진 속 음식을 분석해 순수 JSON만 반환하세요. 설명이나 마크다운은 쓰지 마세요.
        한국어를 사용하고 다음 필드를 정확히 포함하세요.
        foods 배열의 각 항목: name, portion, calories, protein, fat, carbs, fiber, sugar, health_rating.
        최상위 필드: total_calories, total_protein, total_fat, total_carbs, health_score, suggestions.
        health_rating은 매우 좋음, 좋음, 보통, 주의 중 하나이며 숫자는 JSON 숫자 타입으로 반환하세요.
        """

        print("[LeanEat][INFO] Gemini 음식 분석 시작 model=\(GeminiModelCatalog.quickVision)")
        let startedAt = Date()

        do {
            let text = try await visionService.analyzeImage(image, customPrompt: prompt)
            let result = try parse(text)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            print("[LeanEat][INFO] Gemini 음식 분석 완료 elapsedMs=\(elapsedMs) foodCount=\(result.foods.count)")
            return result
        } catch {
            let nsError = error as NSError
            print("[LeanEat][ERROR] Gemini 음식 분석 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            throw error
        }
    }

    private func parse(_ text: String) throws -> FoodNutritionResponse {
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        jsonText = jsonText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = jsonText.firstIndex(of: "{"),
           let end = jsonText.lastIndex(of: "}") {
            jsonText = String(jsonText[start...end])
        }

        guard let data = jsonText.data(using: .utf8) else {
            throw LeanEatError.invalidJSON
        }

        do {
            return try JSONDecoder().decode(FoodNutritionResponse.self, from: data)
        } catch {
            let nsError = error as NSError
            print("[LeanEat][ERROR] 영양 JSON 파싱 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) responseBytes=\(data.count)")
            throw LeanEatError.invalidJSON
        }
    }
}

enum LeanEatError: LocalizedError {
    case invalidImage
    case emptyResponse
    case invalidResponse
    case invalidJSON
    case network(domain: String, code: Int, message: String)
    case apiError(statusCode: Int, requestID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "이미지를 처리할 수 없습니다"
        case .emptyResponse:
            return "AI가 빈 응답을 반환했습니다"
        case .invalidResponse:
            return "AI 응답 형식이 올바르지 않습니다"
        case .invalidJSON:
            return "영양 정보를 해석하지 못했습니다. 다시 시도하세요"
        case .network(let domain, let code, let message):
            return "네트워크 오류: \(message) (\(domain) \(code))"
        case .apiError(let statusCode, let requestID, let message):
            let suffix = requestID == "-" ? "" : " 요청 ID: \(requestID)"
            return "API 오류 \(statusCode): \(message)\(suffix)"
        }
    }
}

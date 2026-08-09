/*
 * 음식 영양 분석 서비스
 * 현재 선택한 비전 API 제공자를 사용하고, 응답/오류 로그에서 자격 증명과 대용량 데이터를 제거한다.
 */

import Foundation
import UIKit

final class LeanEatService {
    private let apiKey: String
    private let provider: APIProvider
    private let baseURL: String
    private let model: String

    init(apiKey: String) {
        self.apiKey = apiKey
        self.provider = VisionAPIConfig.provider
        self.baseURL = VisionAPIConfig.baseURL
        self.model = VisionAPIConfig.model
    }

    struct ChatCompletionRequest: Codable {
        let model: String
        let messages: [Message]

        struct Message: Codable {
            let role: String
            let content: [Content]

            struct Content: Codable {
                let type: String
                let text: String?
                let imageUrl: ImageURL?

                enum CodingKeys: String, CodingKey {
                    case type
                    case text
                    case imageUrl = "image_url"
                }

                struct ImageURL: Codable {
                    let url: String
                }
            }
        }
    }

    struct ChatCompletionResponse: Codable {
        let choices: [Choice]?

        struct Choice: Codable {
            let message: Message?

            struct Message: Codable {
                let content: String?
            }
        }
    }

    func analyzeFood(_ image: UIImage) async throws -> FoodNutritionResponse {
        guard let imageData = image.jpegData(compressionQuality: 0.78) else {
            print("[LeanEat][ERROR] JPEG 변환 실패 size=\(image.size.width)x\(image.size.height)")
            throw LeanEatError.invalidImage
        }

        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let nutritionPrompt = """
당신은 전문 영양사 AI입니다. 사진 속 음식을 분석하고 반드시 순수 JSON만 반환하세요.
설명, 마크다운 코드 블록, 인사말을 추가하지 마세요.
모든 음식 이름, 분량, 평가와 조언은 자연스러운 한국어로 작성하세요.

JSON 스키마:
{
  "foods": [
    {
      "name": "음식 이름",
      "portion": "예상 분량, 예: 1그릇 또는 100g",
      "calories": 0,
      "protein": 0.0,
      "fat": 0.0,
      "carbs": 0.0,
      "fiber": 0.0,
      "sugar": 0.0,
      "health_rating": "매우 좋음 또는 좋음 또는 보통 또는 주의"
    }
  ],
  "total_calories": 0,
  "total_protein": 0.0,
  "total_fat": 0.0,
  "total_carbs": 0.0,
  "health_score": 0,
  "suggestions": ["영양 조언 1", "영양 조언 2", "영양 조언 3"]
}

사진만으로 확정할 수 없는 수치는 합리적으로 추정하되, JSON 형식과 숫자 타입을 지키세요.
"""

        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(
                    role: "user",
                    content: [
                        .init(type: "image_url", text: nil, imageUrl: .init(url: dataURL)),
                        .init(type: "text", text: nutritionPrompt, imageUrl: nil)
                    ]
                )
            ]
        )

        print("[LeanEat][INFO] 분석 시작 provider=\(provider.displayName) model=\(model) imageBytes=\(imageData.count)")
        let startedAt = Date()
        let responseText = try await makeRequest(request)
        let result = try parseNutritionResponse(responseText)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        print("[LeanEat][INFO] 분석 완료 elapsedMs=\(elapsedMs) foodCount=\(result.foods.count) healthScore=\(result.healthScore)")
        return result
    }

    private func makeRequest(_ requestBody: ChatCompletionRequest) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            print("[LeanEat][ERROR] 잘못된 API URL baseURL=\(baseURL)")
            throw LeanEatError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        for (key, value) in VisionAPIConfig.headers(with: apiKey) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            let nsError = error as NSError
            print("[LeanEat][ERROR] 요청 인코딩 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            throw error
        }

        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let nsError = error as NSError
            print("[LeanEat][ERROR] 네트워크 요청 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            throw LeanEatError.network(domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[LeanEat][ERROR] HTTP 응답이 아님 responseType=\(type(of: response))")
            throw LeanEatError.invalidResponse
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "request-id")
            ?? httpResponse.value(forHTTPHeaderField: "x-dashscope-request-id")
            ?? "-"
        print("[LeanEat][HTTP] status=\(httpResponse.statusCode) elapsedMs=\(elapsedMs) bytes=\(data.count) requestID=\(requestID)")

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = safeResponsePreview(data)
            print("[LeanEat][ERROR] API 오류 status=\(httpResponse.statusCode) requestID=\(requestID) body=\(message)")
            throw LeanEatError.apiError(statusCode: httpResponse.statusCode, requestID: requestID, message: message)
        }

        do {
            let apiResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let content = apiResponse.choices?.first?.message?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LeanEatError.emptyResponse
            }
            return content
        } catch let error as LeanEatError {
            throw error
        } catch {
            let nsError = error as NSError
            print("[LeanEat][ERROR] API 응답 디코딩 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) bodyPreview=\(safeResponsePreview(data))")
            throw LeanEatError.invalidResponse
        }
    }

    private func parseNutritionResponse(_ text: String) throws -> FoodNutritionResponse {
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

        guard let jsonData = jsonText.data(using: .utf8) else {
            print("[LeanEat][ERROR] 영양 JSON을 UTF-8로 변환하지 못함 textLength=\(text.count)")
            throw LeanEatError.invalidJSON
        }

        do {
            return try JSONDecoder().decode(FoodNutritionResponse.self, from: jsonData)
        } catch {
            let nsError = error as NSError
            // 음식명과 조언은 사용자의 사진에서 추론된 민감 정보일 수 있어 원문 전체를 로그에 남기지 않는다.
            print("[LeanEat][ERROR] 영양 JSON 파싱 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) jsonLength=\(jsonData.count) preview=\(sanitize(String(jsonText.prefix(600))))")
            throw LeanEatError.invalidJSON
        }
    }

    private func safeResponsePreview(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "UTF-8로 해석할 수 없는 응답 \(data.count)바이트"
        }
        return sanitize(String(text.prefix(1_000)))
    }

    private func sanitize(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+\-/=]+"#, "$1<숨김>"),
            (#"(?i)([?&](?:token|key|api_key|apikey)=)[^&\s]+"#, "$1<숨김>"),
            (#"data:image/[^;\s]+;base64,[A-Za-z0-9+/=]+"#, "<이미지 데이터 생략>"),
            (#"(?<![A-Za-z0-9])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9])"#, "<대용량 데이터 생략>")
        ]

        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
        }
        return output
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
            let requestSuffix = requestID == "-" ? "" : " 요청 ID: \(requestID)"
            return "API 오류 \(statusCode): \(message)\(requestSuffix)"
        }
    }
}

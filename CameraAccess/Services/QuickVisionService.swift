/*
 * Quick Vision Service
 * 이미지 인식 API 호출 및 진단 로그를 담당한다.
 */

import Foundation
import UIKit

final class QuickVisionService {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let provider: APIProvider

    init(apiKey: String, baseURL: String? = nil, model: String? = nil) {
        self.apiKey = apiKey
        self.provider = VisionAPIConfig.provider
        self.baseURL = baseURL ?? VisionAPIConfig.baseURL
        self.model = model ?? VisionAPIConfig.model
    }

    convenience init() {
        self.init(
            apiKey: VisionAPIConfig.apiKey,
            baseURL: VisionAPIConfig.baseURL,
            model: VisionAPIConfig.model
        )
    }

    // MARK: - API models

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
            let delta: Delta?

            struct Message: Codable {
                let content: String?
            }

            struct Delta: Codable {
                let content: String?
            }
        }
    }

    // MARK: - Public API

    func analyzeImage(_ image: UIImage, customPrompt: String? = nil) async throws -> String {
        let startedAt = Date()

        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            print("[QuickVisionAPI][ERROR] JPEG 변환 실패 size=\(image.size.width)x\(image.size.height)")
            throw QuickVisionError.invalidImage
        }

        let prompt = customPrompt ?? QuickVisionModeManager.staticPrompt
        let base64String = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64String)"

        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(
                    role: "user",
                    content: [
                        .init(type: "image_url", text: nil, imageUrl: .init(url: dataURL)),
                        .init(type: "text", text: prompt, imageUrl: nil)
                    ]
                )
            ]
        )

        print("[QuickVisionAPI][INFO] 분석 준비 provider=\(provider.displayName) model=\(model) imageBytes=\(imageData.count) promptLength=\(prompt.count)")

        let result = try await makeRequest(request)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        print("[QuickVisionAPI][INFO] 분석 완료 elapsedMs=\(elapsedMs) resultLength=\(result.count)")
        return result
    }

    // MARK: - Request

    private func makeRequest(_ requestBody: ChatCompletionRequest) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            print("[QuickVisionAPI][ERROR] 잘못된 URL baseURL=\(baseURL)")
            throw QuickVisionError.invalidResponse
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
            print("[QuickVisionAPI][ERROR] 요청 JSON 인코딩 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            throw error
        }

        let requestBytes = request.httpBody?.count ?? 0
        print("[QuickVisionAPI][HTTP] POST url=\(url.absoluteString) provider=\(provider.displayName) model=\(model) requestBytes=\(requestBytes) timeout=\(request.timeoutInterval)s")

        let data: Data
        let response: URLResponse
        let startedAt = Date()

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let nsError = error as NSError
            print("[QuickVisionAPI][ERROR] 네트워크 요청 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo) url=\(url.host ?? "-")")
            throw QuickVisionError.network(
                domain: nsError.domain,
                code: nsError.code,
                message: nsError.localizedDescription
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[QuickVisionAPI][ERROR] HTTP 응답이 아님 responseType=\(type(of: response)) bytes=\(data.count)")
            throw QuickVisionError.invalidResponse
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "request-id")
            ?? httpResponse.value(forHTTPHeaderField: "x-dashscope-request-id")
            ?? "-"

        print("[QuickVisionAPI][HTTP] response status=\(httpResponse.statusCode) elapsedMs=\(elapsedMs) bytes=\(data.count) contentType=\(contentType) requestID=\(requestID)")

        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage = extractServerError(from: data)
            print("[QuickVisionAPI][ERROR] API 응답 오류 status=\(httpResponse.statusCode) requestID=\(requestID) body=\(serverMessage)")
            throw QuickVisionError.apiError(
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                message: serverMessage
            )
        }

        let responseBody: ChatCompletionResponse
        do {
            responseBody = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            let nsError = error as NSError
            let preview = safePreview(data)
            print("[QuickVisionAPI][ERROR] 응답 JSON 디코딩 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) bodyPreview=\(preview)")
            throw QuickVisionError.invalidResponse
        }

        guard let firstChoice = responseBody.choices?.first else {
            print("[QuickVisionAPI][ERROR] choices가 비어 있음 responseBytes=\(data.count)")
            throw QuickVisionError.emptyResponse
        }

        let content = firstChoice.message?.content ?? firstChoice.delta?.content
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[QuickVisionAPI][ERROR] 첫 choice의 content가 비어 있음")
            throw QuickVisionError.emptyResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractServerError(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? String(describing: error)
                let code = error["code"].map(String.init(describing:)) ?? "-"
                return sanitize("code=\(code), message=\(message)")
            }

            if let message = json["message"] as? String {
                return sanitize(message)
            }

            return sanitize(String(describing: json))
        }

        return safePreview(data)
    }

    private func safePreview(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "UTF-8로 해석할 수 없는 응답 \(data.count)바이트"
        }
        return sanitize(String(text.prefix(2_000)))
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

// MARK: - Errors

enum QuickVisionError: LocalizedError {
    case noDevice
    case streamNotReady
    case frameTimeout
    case invalidImage
    case emptyResponse
    case invalidResponse
    case network(domain: String, code: Int, message: String)
    case apiError(statusCode: Int, requestID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "안경이 연결되지 않았습니다. Meta View에서 먼저 안경을 연결하세요"
        case .streamNotReady:
            return "영상 스트림을 시작하지 못했습니다. 안경 연결 상태를 확인하세요"
        case .frameTimeout:
            return "영상 프레임 대기 시간이 초과되었습니다. 다시 시도하세요"
        case .invalidImage:
            return "이미지를 처리할 수 없습니다"
        case .emptyResponse:
            return "AI가 빈 응답을 반환했습니다. 다시 시도하세요"
        case .invalidResponse:
            return "AI 응답 형식이 올바르지 않습니다"
        case .network(let domain, let code, let message):
            return "네트워크 오류가 발생했습니다. \(message) (\(domain) \(code))"
        case .apiError(let statusCode, let requestID, let message):
            let requestSuffix = requestID == "-" ? "" : " 요청 ID: \(requestID)"
            return "API 오류 \(statusCode): \(message)\(requestSuffix)"
        }
    }
}

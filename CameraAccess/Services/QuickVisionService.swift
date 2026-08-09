/*
 * Google Gemini 기반 Quick Vision 이미지 분석 서비스
 *
 * JPEG 이미지와 한국어 프롬프트를 Gemini generateContent API에 전송한다.
 * 인증값, 프롬프트 원문, 이미지 Base64와 응답 본문은 진단 로그에 기록하지 않는다.
 */

import Foundation
import UIKit

final class QuickVisionService {
    private let apiKey: String
    private let baseURL: String
    private let model: String

    init(apiKey: String, baseURL: String? = nil, model: String? = nil) {
        self.apiKey = apiKey
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

    // MARK: - Gemini request/response models

    private struct GenerateContentRequest: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig

        struct Content: Encodable {
            let role: String
            let parts: [Part]
        }

        struct Part: Encodable {
            let text: String?
            let inlineData: InlineData?

            enum CodingKeys: String, CodingKey {
                case text
                case inlineData = "inline_data"
            }
        }

        struct InlineData: Encodable {
            let mimeType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
            }
        }

        struct GenerationConfig: Encodable {
            let temperature: Double
            let maxOutputTokens: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case maxOutputTokens = "maxOutputTokens"
            }
        }
    }

    private struct GenerateContentResponse: Decodable {
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?

        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?

            struct Content: Decodable {
                let parts: [Part]?

                struct Part: Decodable {
                    let text: String?
                }
            }
        }

        struct PromptFeedback: Decodable {
            let blockReason: String?
        }
    }

    private struct GeminiErrorEnvelope: Decodable {
        let error: GeminiErrorBody?

        struct GeminiErrorBody: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }
    }

    // MARK: - Public API

    func analyzeImage(_ image: UIImage, customPrompt: String? = nil) async throws -> String {
        let startedAt = Date()

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[QuickVisionAPI][ERROR] Google Gemini 자격 증명이 설정되지 않음")
            throw QuickVisionError.apiKeyMissing
        }

        guard let imageData = image.jpegData(compressionQuality: 0.72) else {
            print("[QuickVisionAPI][ERROR] JPEG 변환 실패 size=\(image.size.width)x\(image.size.height)")
            throw QuickVisionError.invalidImage
        }

        let prompt = (customPrompt ?? QuickVisionModeManager.staticPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            print("[QuickVisionAPI][ERROR] 빈 프롬프트로 분석 요청 거부")
            throw QuickVisionError.invalidResponse
        }

        let requestBody = GenerateContentRequest(
            contents: [
                .init(
                    role: "user",
                    parts: [
                        .init(text: prompt, inlineData: nil),
                        .init(
                            text: nil,
                            inlineData: .init(
                                mimeType: "image/jpeg",
                                data: imageData.base64EncodedString()
                            )
                        )
                    ]
                )
            ],
            generationConfig: .init(
                temperature: 0.2,
                maxOutputTokens: 768
            )
        )

        print(
            "[QuickVisionAPI][INFO] Gemini 분석 준비 model=\(model) "
            + "imageBytes=\(imageData.count) promptLength=\(prompt.count)"
        )

        let result = try await makeRequest(requestBody)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        print("[QuickVisionAPI][INFO] Gemini 분석 완료 elapsedMs=\(elapsedMs) resultLength=\(result.count)")
        return result
    }

    // MARK: - Request

    private func makeRequest(_ requestBody: GenerateContentRequest) async throws -> String {
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else {
            print("[QuickVisionAPI][ERROR] Gemini URL 생성 실패 model=\(model)")
            throw QuickVisionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        for (header, value) in VisionAPIConfig.headers(with: apiKey) {
            request.setValue(value, forHTTPHeaderField: header)
        }

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            let nsError = error as NSError
            print(
                "[QuickVisionAPI][ERROR] Gemini 요청 인코딩 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
            )
            throw error
        }

        print(
            "[QuickVisionAPI][HTTP] POST host=\(url.host ?? "-") model=\(model) "
            + "requestBytes=\(request.httpBody?.count ?? 0) timeout=\(Int(request.timeoutInterval))s"
        )

        let startedAt = Date()
        let data: Data
        let response: URLResponse

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            (data, response) = try await session.data(for: request)
        } catch {
            let nsError = error as NSError
            print(
                "[QuickVisionAPI][ERROR] Gemini 네트워크 요청 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
            )
            throw QuickVisionError.network(
                domain: nsError.domain,
                code: nsError.code,
                message: nsError.localizedDescription
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[QuickVisionAPI][ERROR] Gemini HTTP 응답 형식 아님 bytes=\(data.count)")
            throw QuickVisionError.invalidResponse
        }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "x-goog-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "request-id")
            ?? "-"
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "-"

        print(
            "[QuickVisionAPI][HTTP] Gemini 응답 status=\(httpResponse.statusCode) "
            + "elapsedMs=\(elapsedMs) bytes=\(data.count) contentType=\(contentType) requestID=\(requestID)"
        )

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractServerError(from: data)
            print(
                "[QuickVisionAPI][ERROR] Gemini API 오류 status=\(httpResponse.statusCode) "
                + "requestID=\(requestID) message=\(message)"
            )
            throw QuickVisionError.apiError(
                statusCode: httpResponse.statusCode,
                requestID: requestID,
                message: message
            )
        }

        let responseBody: GenerateContentResponse
        do {
            responseBody = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            let nsError = error as NSError
            print(
                "[QuickVisionAPI][ERROR] Gemini 응답 디코딩 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) "
                + "responseBytes=\(data.count)"
            )
            throw QuickVisionError.invalidResponse
        }

        if let blockReason = responseBody.promptFeedback?.blockReason, !blockReason.isEmpty {
            print("[QuickVisionAPI][WARN] Gemini 요청 차단 reason=\(sanitize(blockReason))")
            throw QuickVisionError.blocked(reason: sanitize(blockReason))
        }

        guard let candidate = responseBody.candidates?.first else {
            print("[QuickVisionAPI][ERROR] Gemini candidates 비어 있음 responseBytes=\(data.count)")
            throw QuickVisionError.emptyResponse
        }

        let result = candidate.content?.parts?
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !result.isEmpty else {
            print(
                "[QuickVisionAPI][ERROR] Gemini 텍스트 응답 비어 있음 "
                + "finishReason=\(candidate.finishReason ?? "-")"
            )
            throw QuickVisionError.emptyResponse
        }

        return result
    }

    private func extractServerError(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data),
           let error = envelope.error {
            let code = error.code.map(String.init) ?? "-"
            let status = sanitize(error.status ?? "-")
            let message = sanitize(error.message ?? "Google Gemini 요청에 실패했습니다")
            return "code=\(code), status=\(status), message=\(message)"
        }
        return "Google Gemini 요청에 실패했습니다"
    }

    private func sanitize(_ text: String) -> String {
        var output = String(text.prefix(1_000))
        let patterns: [(String, String)] = [
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+\-/=]+"#, "$1<숨김>"),
            (#"(?i)([?&](?:token|key|api_key|apikey)=)[^&\s]+"#, "$1<숨김>"),
            (#"\bAIza[0-9A-Za-z_-]{20,}\b"#, "<숨김>"),
            (#"data:(?:image|audio)/[^;\s]+;base64,[A-Za-z0-9+/=]+"#, "<대용량 데이터 생략>"),
            (#"(?<![A-Za-z0-9])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9])"#, "<대용량 데이터 생략>")
        ]

        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: replacement
            )
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
    case apiKeyMissing
    case emptyResponse
    case invalidResponse
    case blocked(reason: String)
    case network(domain: String, code: Int, message: String)
    case apiError(statusCode: Int, requestID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "안경이 연결되지 않았습니다. Meta View에서 먼저 안경을 연결하세요"
        case .streamNotReady:
            return "영상 스트림을 시작하지 못했습니다. 안경 연결 상태를 확인하세요"
        case .frameTimeout:
            return "영상 프레임을 받지 못했습니다. 다시 시도하세요"
        case .invalidImage:
            return "이미지를 처리할 수 없습니다"
        case .apiKeyMissing:
            return "설정에서 Google Gemini API Key를 먼저 등록하세요"
        case .emptyResponse:
            return "Google Gemini가 빈 응답을 반환했습니다"
        case .invalidResponse:
            return "Google Gemini 응답 형식이 올바르지 않습니다"
        case .blocked(let reason):
            return "안전 정책으로 요청을 처리하지 못했습니다. \(reason)"
        case .network(let domain, let code, let message):
            return "네트워크 오류: \(message) (\(domain) \(code))"
        case .apiError(let statusCode, let requestID, let message):
            let requestSuffix = requestID == "-" ? "" : " 요청 ID: \(requestID)"
            return "Google Gemini API 오류 \(statusCode): \(message)\(requestSuffix)"
        }
    }
}

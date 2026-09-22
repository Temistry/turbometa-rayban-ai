/*
 * 회의 통역기 Gemini 서비스
 *
 * 레인 A(전문용어 귓속말 설명)와 레인 B(주장 근거 조사)의 문장 생성을 담당한다.
 * 인증값은 기존 Google Gemini Key(VisionAPIConfig/APIKeyManager)를 재사용한다.
 */

import Foundation

struct MeetingFactLink: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let urlString: String
}

struct MeetingFactCheckResult: Equatable {
    let summary: String
    let links: [MeetingFactLink]
}

struct MeetingExplanation: Equatable {
    let term: String
    let text: String
}

enum MeetingGeminiError: Error, Equatable {
    case missingAPIKey
    case http(Int)
    case invalidResponse
}

final class MeetingGeminiService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func explain(
        utterance: String,
        recentContext: String,
        sceneContext: String?
    ) async throws -> MeetingExplanation {
        let prompt = """
        당신은 회의 전문용어 통역기다. 아래 '현재 발화'에서 비즈니스·기술 전문용어를 찾아 +        착용자에게 귓속말로 설명한다. 규칙: 한국어 구어체 1문장, 최대 60자, 용어명으로 시작하고 +        사전 지식 없이도 이해되게. 설명할 용어가 없으면 발화 요점을 짧게 전달한다.
        직전 발화: \(recentContext.isEmpty ? "(없음)" : recentContext)
        화면 맥락: \(sceneContext.flatMap { $0.isEmpty ? nil : $0 } ?? "(없음)")
        현재 발화: \(utterance)
        출력은 JSON 하나만: {"term": "발화에서 찾은 전문용어 원문", "text": "귓속말 설명 문장"}
        """

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 256,
                "responseMimeType": "application/json"
            ]
        ]

        let responseObject = try await post(body)
        guard let raw = Self.parseText(responseObject),
              let explanation = Self.parseExplanation(raw) else {
            throw MeetingGeminiError.invalidResponse
        }
        return explanation
    }

    func factCheck(claim: String) async throws -> MeetingFactCheckResult {
        let prompt = """
        아래 회의 발언 주장의 진위를 웹에서 조사한다. 요약은 한국어 1~2문장으로 +        '지지 근거 N건', '반박 근거 N건', '판단 불가' 중 하나로 시작한다.
        발언: \(claim)
        """

        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 512]
        ]

        let responseObject = try await post(body)
        let summary = Self.parseText(responseObject) ?? "판단 불가"
        return MeetingFactCheckResult(
            summary: summary,
            links: Self.parseGroundingLinks(responseObject)
        )
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard !VisionAPIConfig.apiKey.isEmpty else {
            throw MeetingGeminiError.missingAPIKey
        }
        guard let url = VisionAPIConfig.generateContentURL() else {
            throw MeetingGeminiError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in VisionAPIConfig.headers(with: VisionAPIConfig.apiKey) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            // 429/503은 잠시 후 1회만 재시도한다. 그 외는 그대로 실패.
            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let (retryData, retryResponse) = try await session.data(for: request)
                if let retryHTTP = retryResponse as? HTTPURLResponse,
                   !(200...299).contains(retryHTTP.statusCode) {
                    throw MeetingGeminiError.http(retryHTTP.statusCode)
                }
                return try Self.decodeObject(retryData)
            }
            throw MeetingGeminiError.http(httpResponse.statusCode)
        }
        return try Self.decodeObject(data)
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingGeminiError.invalidResponse
        }
        return object
    }

    static func parseText(_ object: [String: Any]) -> String? {
        guard let candidates = object["candidates"] as? [[String: Any]],
              let candidate = candidates.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        let text = parts
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func parseExplanation(_ raw: String) -> MeetingExplanation? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let explanationText = object["text"] as? String else {
            return nil
        }

        let trimmedText = explanationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        let term = (object["term"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MeetingExplanation(term: term, text: trimmedText)
    }

    static func parseGroundingLinks(_ object: [String: Any]) -> [MeetingFactLink] {
        guard let candidates = object["candidates"] as? [[String: Any]],
              let candidate = candidates.first,
              let groundingMetadata = candidate["groundingMetadata"] as? [String: Any],
              let chunks = groundingMetadata["groundingChunks"] as? [[String: Any]] else {
            return []
        }

        var links: [MeetingFactLink] = []
        var seenURLs = Set<String>()
        for chunk in chunks {
            guard let web = chunk["web"] as? [String: Any],
                  let urlString = web["uri"] as? String,
                  !urlString.isEmpty,
                  !seenURLs.contains(urlString) else {
                continue
            }
            seenURLs.insert(urlString)
            let title = (web["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? urlString
            links.append(MeetingFactLink(title: title, urlString: urlString))
            if links.count == 3 {
                break
            }
        }
        return links
    }
}

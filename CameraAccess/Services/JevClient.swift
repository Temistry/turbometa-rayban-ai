/*
 * TypeSafe Jev(System One) 판단 클라이언트
 *
 * 회의 통역기의 신경 반사 계층. 발화 텍스트를 state로 보내고 사전에 정의한
 * choice 질문(개입 여부, 후속 레인)에 대한 확률적 판단을 받는다.
 * 인증값은 APIKeyManager의 Keychain 항목에서만 읽고 로그에 남기지 않는다.
 */

import Foundation

struct JevAnswer: Equatable {
    let value: String
    let confidence: Double
}

enum JevUtteranceLane: String, Equatable {
    case explain
    case factcheck
    case none
}

struct JevUtteranceDecision: Equatable {
    let needsExplanation: Bool
    let explanationConfidence: Double
    let lane: JevUtteranceLane

    static func make(answers: [String: JevAnswer]) -> JevUtteranceDecision {
        let explanation = answers["needs_explanation"]
        let laneRaw = answers["lane"]?.value ?? JevUtteranceLane.none.rawValue
        return JevUtteranceDecision(
            needsExplanation: explanation?.value == "yes",
            explanationConfidence: explanation?.confidence ?? 0,
            lane: JevUtteranceLane(rawValue: laneRaw) ?? .none
        )
    }
}

enum JevClientError: Error, Equatable {
    case missingAPIKey
    case transport(String)
    case http(Int)
    case invalidResponse

    var code: String {
        switch self {
        case .missingAPIKey:
            return "E-JEV-401"
        case .transport, .http:
            return "E-JEV-503"
        case .invalidResponse:
            return "E-JEV-500"
        }
    }

    var message: String {
        switch self {
        case .missingAPIKey:
            return "Jev API 키가 설정되지 않았습니다."
        case .transport:
            return "판단 서비스에 연결하지 못했습니다."
        case .http:
            return "판단 서비스가 요청을 거부했습니다."
        case .invalidResponse:
            return "판단 서비스 응답을 해석하지 못했습니다."
        }
    }
}

final class JevClient {
    static let shared = JevClient()

    private let session: URLSession
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let model = "jev-latest"

    init(session: URLSession = .shared) {
        self.session = session
    }

    static var storedAPIKey: String? {
        guard let key = APIKeyManager.shared.getJevAPIKey(), !key.isEmpty else { return nil }
        return key
    }

    func evaluate(utterance: String, previousUtterance: String?) async throws -> JevUtteranceDecision {
        var state = "사용자는 한국어 회의에 참여 중이고 스마트 안경 통역 도우미가 대화를 듣고 있다.\n"
        if let previousUtterance, !previousUtterance.isEmpty {
            state += "직전 발화: \(previousUtterance)\n"
        }
        state += "현재 발화: \(utterance)"

        let questions: [String: Any] = [
            "needs_explanation": [
                "type": "choice",
                "instructions": "현재 발화에 비즈니스·기술 전문용어가 있어 즉석 설명이 도움이 되는가?",
                "criteria": [
                    "yes": "설명이 필요한 전문용어가 포함되어 있다",
                    "no": "일상 표현뿐이라 설명이 불필요하다"
                ]
            ],
            "lane": [
                "type": "choice",
                "instructions": "이 발화에 적절한 후속 작업은 무엇인가?",
                "criteria": [
                    "explain": "전문용어 설명(귓속말)",
                    "factcheck": "웹 근거가 필요한 검증 가능한 사실 주장",
                    "none": "후속 작업이 불필요하다"
                ]
            ]
        ]

        let answers = try await evaluate(state: state, questions: questions)
        guard let explanation = answers["needs_explanation"],
              ["yes", "no"].contains(explanation.value),
              let lane = answers["lane"], JevUtteranceLane(rawValue: lane.value) != nil else {
            throw JevClientError.invalidResponse
        }
        return JevUtteranceDecision.make(answers: answers)
    }

    func evaluate(state: String, questions: [String: Any]) async throws -> [String: JevAnswer] {
        guard let apiKey = Self.storedAPIKey else {
            throw JevClientError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12

        let body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": questions
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        let startedAt = Date()
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingJev", "transport code=\((error as NSError).code)")
            throw JevClientError.transport(error.localizedDescription)
        }
        DeveloperConsole.shared.log(.info, category: "MeetingJev", "status=\((response as? HTTPURLResponse)?.statusCode ?? 0) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw JevClientError.http(httpResponse.statusCode)
        }

        return try Self.parseAnswers(data)
    }

    static func parseAnswers(_ data: Data) throws -> [String: JevAnswer] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answersObject = object["answers"] as? [String: Any] else {
            throw JevClientError.invalidResponse
        }

        var answers: [String: JevAnswer] = [:]
        for (key, rawAnswer) in answersObject {
            guard let answerObject = rawAnswer as? [String: Any],
                  let value = answerObject["choice"] as? String else {
                continue
            }
            let probabilities = answerObject["probabilities"] as? [String: Double]
            guard let confidence = answerObject["confidence"] as? Double ?? probabilities?[value],
                  confidence.isFinite, (0...1).contains(confidence) else {
                throw JevClientError.invalidResponse
            }
            answers[key] = JevAnswer(value: value, confidence: confidence)
        }

        guard !answers.isEmpty else {
            throw JevClientError.invalidResponse
        }
        return answers
    }
}

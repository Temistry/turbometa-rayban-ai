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
    /// 비즈니스(business)·개발(dev)·그 외(none).
    let category: String

    static func make(answers: [String: JevAnswer]) -> JevUtteranceDecision {
        let explanation = answers["needs_explanation"]
        let laneRaw = answers["lane"]?.value ?? JevUtteranceLane.none.rawValue
        return JevUtteranceDecision(
            needsExplanation: explanation?.value == "yes",
            explanationConfidence: explanation?.confidence ?? 0,
            lane: JevUtteranceLane(rawValue: laneRaw) ?? .none,
            category: answers["category"]?.value ?? "none"
        )
    }
}

enum JevClientError: Error, Equatable {
/// 상대 발언 1차 판단: 허점 분석을 할지와 종류.
struct JevCatchDecision: Equatable {
    static let kinds = ["unsupported", "leap", "contradiction", "claim", "none"]
    /// 이 확신도 이상일 때만 Gemini 분석을 요청한다.
    static let analyzeThreshold = 0.55

    let kind: String
    let confidence: Double

    var shouldAnalyze: Bool {
        kind != "none" && confidence >= Self.analyzeThreshold
    }

    static func make(answers: [String: JevAnswer]) -> JevCatchDecision? {
        guard let answer = answers["catch"], kinds.contains(answer.value) else { return nil }
        return JevCatchDecision(kind: answer.value, confidence: answer.confidence)
    }
}

enum JevClientError: Error, Equatable {
    case missingAPIKey
    case keyLocked
    case transport(String)
    case http(Int)
    case invalidResponse

    var code: String {
        switch self {
        case .missingAPIKey:
            return "E-JEV-401"
        case .keyLocked:
            return "E-JEV-423"
        case .http(401), .http(403):
            return "E-JEV-403"
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
        case .keyLocked:
            return "아이폰이 잠겨 있어 Jev API 키를 읽지 못했습니다. 잠금을 해제한 뒤 다시 시작하세요."
        case .http(401), .http(403):
            return "Jev가 API 키를 거부했습니다. 설정에서 키를 확인하세요."
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
        try? loadAPIKey()
    }

    /// 키가 없을 때와 기기 잠금으로 못 읽었을 때를 다른 오류로 구분한다.
    static func loadAPIKey() throws -> String {
        switch APIKeyManager.shared.readJevAPIKey() {
        case .found(let key) where !key.isEmpty:
            return key
        case .locked:
            throw JevClientError.keyLocked
        default:
            throw JevClientError.missingAPIKey
        }
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
                "instructions": "현재 발화에 비즈니스 또는 개발 도메인의 전문용어·약어가 있어 즉석 설명이 필요한가?",
                "criteria": [
                    "yes": "재무·회계·전략·마케팅·법무 또는 소프트웨어·인프라·데이터·보안 전문용어가 포함되어 있다",
                    "no": "두 도메인 밖이거나 설명이 불필요하다"
                ]
            ],
            "category": [
                "type": "choice",
                "instructions": "발화의 난해한 표현이 어느 분야 용어인가? 두 도메인 밖이면 none이다.",
                "criteria": [
                    "business": "비즈니스 용어다(재무·회계·전략·마케팅·영업·법무·계약)",
                    "dev": "개발 용어다(소프트웨어·인프라·클라우드·데이터·보안)",
                    "none": "두 도메인 밖이다(일상어 또는 다른 분야 전문용어)"
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
        guard let category = answers["category"],
              ["business", "dev", "none"].contains(category.value) else {
            throw JevClientError.invalidResponse
        }
        return JevUtteranceDecision.make(answers: answers)
    }

    func evaluate(state: String, questions: [String: Any]) async throws -> [String: JevAnswer] {
        try await evaluateRaw(state: state, questions: questions)
    }

    /// 상대 발언에 짚을 허점이 있는지 판단한다.
    func evaluateCatch(statement: String, earlier: String, speakerKnown: Bool) async throws -> JevCatchDecision {
        let who = speakerKnown ? "상대" : "대화 참여자"
        var state = "사용자는 상대의 양해를 받고 대화를 분석 중이다. \(who)의 발언에서 따져 볼 허점을 찾는다.\n"
        if !earlier.isEmpty {
            state += "\(who)의 이전 발언: \(earlier)\n"
        }
        state += "\(who)의 새 발언: \(statement)"

        let questions: [String: Any] = [
            "catch": [
                "type": "choice",
                "instructions": "새 발언에서 가장 따져 볼 만한 점은 무엇인가? 없으면 none이다.",
                "criteria": [
                    "unsupported": "근거 없이 단정한다",
                    "leap": "논리가 비약한다(성급한 일반화, 상관과 인과 혼동, 권위·다수 호소 등)",
                    "contradiction": "이전 발언과 충돌한다",
                    "claim": "확인이 필요한 수치·통계·사실을 주장한다",
                    "none": "짚을 점이 없다(인사, 질문, 동의, 일반적인 의견)"
                ]
            ]
        ]
        let answers = try await evaluateRaw(state: state, questions: questions)
        guard let decision = JevCatchDecision.make(answers: answers) else {
            throw JevClientError.invalidResponse
        }
        return decision
    }

    private func evaluateRaw(state: String, questions: [String: Any]) async throws -> [String: JevAnswer] {
        let apiKey = try Self.loadAPIKey()

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

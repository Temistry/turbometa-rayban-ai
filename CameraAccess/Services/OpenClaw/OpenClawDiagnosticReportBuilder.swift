import Foundation

struct OpenClawDiagnosticReportBuilder {
    enum BuildError: LocalizedError, Equatable {
        case emptyUserMessage
        case noRelevantLogs

        var errorDescription: String? {
            switch self {
            case .emptyUserMessage:
                return "openclaw.diagnostic.error.message_required".localized
            case .noRelevantLogs:
                return "openclaw.diagnostic.error.no_logs".localized
            }
        }
    }

    static let maximumUserMessageLength = 1_000
    static let maximumLogLines = 80
    static let maximumReportLength = 12_000

    private static let allowedPrefixes = [
        "[TTS][AUDIO]",
        "[TTS][QUEUE]",
        "[TTS][START]",
        "[TTS][INFO]",
        "[TTS][WARN]",
        "[TTS][ERROR]",
        "[Galvis][AUDIO]",
        "[Galvis][TTS]",
        "[Galvis][STT]",
        "[Galvis][ERROR]",
        "[OpenClaw][TTS]",
        "[AppLifecycle][INFO]"
    ]

    private static let blockedTerms = [
        "transcript",
        "userInfo",
        "MetricKit",
        "stack=",
        "sessionKey",
        "deviceName",
        "portName"
    ]

    static func makePrompt(
        userMessage: String,
        entries: [DeveloperLogEntry]
    ) throws -> String {
        let normalizedMessage = userMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else { throw BuildError.emptyUserMessage }

        let boundedMessage = String(normalizedMessage.prefix(maximumUserMessageLength))
        let safeMessage = removeDisallowedIdentifiers(
            SensitiveDataRedactor.redact(boundedMessage)
        )
        let relevant = entries.suffix(maximumLogLines * 3).compactMap(sanitizeEntry)
        guard !relevant.isEmpty else { throw BuildError.noRelevantLogs }

        let selected = Array(relevant.suffix(maximumLogLines))
        let omittedCount = max(0, relevant.count - selected.count)
        let omission = omittedCount > 0 ? "\n이전 허용 로그 \(omittedCount)줄 생략" : ""

        var prompt = """
        [TurboMeta 내부 TTS 진단 요청]

        [사용자 설명]
        \(safeMessage)

        [선별된 기기 진단]
        \(selected.joined(separator: "\n"))\(omission)

        [분석 요청]
        관찰된 로그만 근거로 답하고, 로그에 없는 내용은 추측이라고 명확히 표시해 주세요.
        다음 순서로 한국어로 정리해 주세요.
        1. 가장 가능성 높은 원인과 신뢰도
        2. 근거가 된 로그 이벤트
        3. 추가로 재현하거나 수집할 정보
        4. 권장 코드 수정 방향(파일 또는 컴포넌트 수준)
        5. 수정 후 검증 체크리스트

        credential, 전체 로그, 사용자 대화 원문을 추가로 요구하지 마세요.
        앱이나 Git 저장소를 직접 수정했다고 주장하지 마세요. 이 요청은 진단 전용입니다.
        """

        prompt = SensitiveDataRedactor.redact(prompt)
        if prompt.count > maximumReportLength {
            prompt = String(prompt.prefix(maximumReportLength))
                + "\n<진단 요청 최대 길이 초과로 생략>"
        }
        return prompt
    }

    private static func sanitizeEntry(_ entry: DeveloperLogEntry) -> String? {
        let message = SensitiveDataRedactor.redact(entry.message)
        guard allowedPrefixes.contains(where: message.hasPrefix) else { return nil }
        guard !blockedTerms.contains(where: { message.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }

        let safeMessage = removeDisallowedIdentifiers(message)
        let timestamp = timestampFormatter.string(from: entry.timestamp)
        return "[\(timestamp)] [\(entry.level.rawValue)] \(safeMessage)"
    }

    private static func removeDisallowedIdentifiers(_ input: String) -> String {
        var output = input
        let replacements: [(String, String)] = [
            (#"(?i)(\b(?:token|apiKey|authorization|cookie|session|deviceId|pairingId)\s*[:=]\s*)[^\s,]+"#, "$1<보안상 숨김>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<식별정보 숨김>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<식별정보 숨김>"),
            (#"https?://\S+"#, "<식별정보 숨김>"),
            (#"(?<![A-Za-z0-9])[A-Za-z0-9+/]{128,}={0,2}(?![A-Za-z0-9])"#, "<식별정보 숨김>")
        ]

        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: replacement
            )
        }
        return output
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

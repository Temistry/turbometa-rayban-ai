/*
 * Shared sensitive-data masking for on-device diagnostics and knowledge logs.
 * This utility does not upload data; it removes credential-like values before local persistence or sharing.
 */

import Foundation

enum SensitiveDataRedactor {
    static let maximumKnowledgeLogTextLength = 20_000

    private static let rules: [(NSRegularExpression, String)] = {
        let definitions: [(String, String)] = [
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+\-/=]+"#, "$1<보안상 숨김>"),
            (#"(?i)(\"(?:api[_ -]?key|apikey|client[_ -]?(?:token|secret)|gateway[_ -]?token|access[_ -]?token|authorization|token|stream[_ -]?key|streamkey)\"\s*:\s*\")[^\"]+(\")"#, "$1<보안상 숨김>$2"),
            (#"(?i)((?:api[_ -]?key|apikey|client[_ -]?(?:token|secret)|gateway[_ -]?token|access[_ -]?token|authorization|token|stream[_ -]?key|streamkey)\s*[:=]\s*)[\"']?[^\s,\"'&]+"#, "$1<보안상 숨김>"),
            (#"(?i)(Cookie\s*:\s*)[^\r\n]+"#, "$1<보안상 숨김>"),
            (#"(?i)([?&](?:token|key|api_key|apikey|access_token|client_secret)=)[^&\s]+"#, "$1<보안상 숨김>"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "<보안상 숨김>"),
            (#"\bAIza[0-9A-Za-z_-]{20,}\b"#, "<보안상 숨김>"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "<보안상 숨김>"),
            (#"(?i)(https?://)[^/\s:@]+:[^@\s/]+@"#, "$1<인증정보 숨김>@"),
            (#"(?i)(rtmps?://[^/\s]+)(?:/[^\s]*)?"#, "$1/<송출 경로 숨김>"),
            (#"data:(?:image|audio)/[^;\s]+;base64,[A-Za-z0-9+/=]+"#, "<대용량 데이터 생략>"),
            (#"(?i)(\"(?:audio|image|data)\"\s*:\s*\")[A-Za-z0-9+/=]{80,}(\")"#, "$1<대용량 데이터 생략>$2"),
            (#"(?i)(\b(?:ACCExternalAccessoryPPIDKey|ACCExternalAccessoryPrimaryUUID|ACCExternalAccessoryProtocolEndpointUUID|IAPAppAccessoryMacAddressKey|IAPAppAccessorySerialNumberKey|IAPAppAccessoryPreferredAppKey|IAPAppAccessoryNameKey)\s*=\s*)[^;\r\n]+"#, "$1<식별정보 숨김>"),
            (#"(?i)(\b(?:세션 ID|sessionID|deviceID|pairingID)\s*[:=]\s*)[^\s,;]+"#, "$1<식별정보 숨김>"),
            (#"(?i)(socketPath\s+from\s+app\s*=\s*)\S+"#, "$1<식별정보 숨김>"),
            (#"(?i)(IAPAppAccessoryCert(?:Data|SerialNumber)Key\s*=\s*)\{[^\r\n]*\}"#, "$1<대용량 데이터 생략>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, "<식별정보 숨김>"),
            (#"(?i)\b(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\b"#, "<식별정보 숨김>"),
            (#"(?<![A-Za-z0-9])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9])"#, "<대용량 데이터 생략>")
        ]

        return definitions.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ input: String) -> String {
        var output = input
        for (regex, replacement) in rules {
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

    static func redactKnowledgeLogText(_ input: String) -> String {
        var output = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > maximumKnowledgeLogTextLength {
            output = String(output.prefix(maximumKnowledgeLogTextLength)) + "\n<최대 기록 길이 초과로 생략>"
        }
        return redact(output)
    }
}

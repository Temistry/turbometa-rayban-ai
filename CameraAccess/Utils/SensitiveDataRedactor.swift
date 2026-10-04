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
            (#"(?i)(\b(?:ACCExternalAccessoryPPIDKey|ACCExternalAccessoryPrimaryUUID|ACCExternalAccessoryProtocolEndpointUUID|IAPAppAccessoryMacAddressKey|IAPAppAccessorySerialNumberKey|IAPAppAccessoryPreferredAppKey|IAPAppAccessoryNameKey|IAPAppAccessoryFirmwareRevisionKey|IAPAppConnectionIDKey)\s*=\s*)[^;\r\n]+"#, "$1<식별정보 숨김>"),
            (#"(?i)(\b(?:세션 ID|sessionID|deviceID|pairingID)\s*[:=]\s*)[^\s,;]+"#, "$1<식별정보 숨김>"),
            (#"(?i)(socketPath\s+from\s+app\s*=\s*)\S+"#, "$1<식별정보 숨김>"),
            (#"(?i)(IAPAppAccessoryCert(?:Data|SerialNumber)Key\s*=\s*)\{[^\r\n]*\}"#, "$1<대용량 데이터 생략>"),
            // BLE/ExternalAccessory pairing frequently synthesizes a display name by appending a
            // random disambiguation suffix to the marketing name, e.g. `Ray-Ban Meta-4F2A` or
            // `Ray-Ban Meta (4F2A9C)`. The base name alone is not sensitive, but the generated
            // suffix is effectively a per-unit identifier, so only the suffix is masked.
            (#"(?i)(\b(?:accessoryDisplayName|peripheralName|localName)\s*[:=]\s*\"?[\w .'-]*?)[- ]\(?[0-9A-Fa-f]{4,}\)?(\"?)"#, "$1<식별정보 숨김>$2"),
            // ExternalAccessory also logs the marketing name followed by a per-unit numeric
            // suffix in prose, for example `For Ray-Ban Meta - 123456 (transport 2)`.
            (#"(?i)(\bFor\s+[A-Za-z][A-Za-z0-9 |.'-]*?\s+-\s+)[0-9A-Fa-f]{4,}(\s*\(transport\s+\d+\))"#, "$1<식별정보 숨김>$2"),
            (#"(?i)(\b(?:firmware|firmwareVersion|firmware[_ -]?build|buildNumber|buildVersion)\s*(?:[:=]|\s)\s*)[^\s,;\"']+"#, "$1<식별정보 숨김>"),
            (#"(?i)(\b(?:nodeId|node[_ -]?id|localNode|remoteNode|localNodeId|remoteNodeId|connectionID)\s*(?:[:=]|\s)\s*)[^\s,;\"']+"#, "$1<식별정보 숨김>"),
            (#"(?i)(\b(?:serviceUUID|serviceId|service\s+ID|characteristicUUID|characteristic\s+ID|channelId|channel[_ -]?id|channel\s+ID)\s*(?:[:=]|\s)\s*)[^\s,;\"']+"#, "$1<식별정보 숨김>"),
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

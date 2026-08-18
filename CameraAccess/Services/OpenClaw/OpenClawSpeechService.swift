import Foundation

enum OpenClawSpeechRate: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var gatewaySpeed: Double {
        switch self {
        case .slow: return 0.85
        case .normal: return 1.0
        case .fast: return 1.15
        }
    }
}

struct OpenClawSpeechAudio {
    let data: Data
    let provider: String
    let mimeType: String?
    let outputFormat: String?
    let fileExtension: String?

    static let maximumDecodedBytes = 6 * 1024 * 1024

    static func decode(payload: [String: Any]) throws -> OpenClawSpeechAudio {
        guard let encoded = payload["audioBase64"] as? String,
              !encoded.isEmpty,
              encoded.utf8.count <= maximumDecodedBytes * 2,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= maximumDecodedBytes else {
            throw OpenClawSpeechError.invalidAudio
        }

        let mimeType = (payload["mimeType"] as? String)?.lowercased()
        let outputFormat = (payload["outputFormat"] as? String)?.lowercased()
        let fileExtension = (payload["fileExtension"] as? String)?.lowercased()
        guard isPlayable(
            mimeType: mimeType,
            outputFormat: outputFormat,
            fileExtension: fileExtension
        ) else {
            throw OpenClawSpeechError.unsupportedAudioFormat
        }

        return OpenClawSpeechAudio(
            data: data,
            provider: payload["provider"] as? String ?? "unknown",
            mimeType: mimeType,
            outputFormat: outputFormat,
            fileExtension: fileExtension
        )
    }

    private static func isPlayable(
        mimeType: String?,
        outputFormat: String?,
        fileExtension: String?
    ) -> Bool {
        let playableMimeTypes: Set<String> = [
            "audio/mpeg",
            "audio/mp3",
            "audio/wav",
            "audio/x-wav",
            "audio/aac",
            "audio/mp4",
            "audio/x-m4a"
        ]
        if let mimeType, playableMimeTypes.contains(mimeType) { return true }

        let metadata = [outputFormat, fileExtension]
            .compactMap { $0 }
            .joined(separator: " ")
        return ["mp3", "mpeg", "wav", "aac", "m4a", "mp4"].contains {
            metadata.contains($0)
        }
    }
}

enum OpenClawSpeechError: LocalizedError {
    case notConnected
    case requestTimeout
    case gateway(code: String, message: String)
    case malformedResponse
    case invalidAudio
    case unsupportedAudioFormat
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "OpenClaw Gateway에 연결되어 있지 않습니다."
        case .requestTimeout:
            return "Gateway 음성 생성 시간이 초과되었습니다."
        case .gateway(_, let message):
            return message
        case .malformedResponse:
            return "Gateway 음성 응답 형식이 올바르지 않습니다."
        case .invalidAudio:
            return "Gateway 음성 데이터가 올바르지 않습니다."
        case .unsupportedAudioFormat:
            return "iPhone에서 재생할 수 없는 Gateway 음성 형식입니다."
        case .playbackFailed:
            return "Gateway 음성을 재생하지 못했습니다."
        }
    }
}

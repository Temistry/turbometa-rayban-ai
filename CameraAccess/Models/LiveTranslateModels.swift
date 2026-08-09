/*
 * 실시간 번역 언어, 음성, 기록과 WebSocket 이벤트 모델
 */

import Foundation

// MARK: - 번역 언어

enum TranslateLanguage: String, CaseIterable, Codable, Identifiable {
    case en
    case zh
    case ja
    case ko
    case fr
    case de
    case ru
    case es
    case pt
    case it
    case yue

    // 입력 언어로만 지원되는 항목
    case id
    case vi
    case th
    case ar
    case hi
    case el
    case tr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "livetranslate.lang.en".localized
        case .zh: return "livetranslate.lang.zh".localized
        case .ja: return "livetranslate.lang.ja".localized
        case .ko: return "livetranslate.lang.ko".localized
        case .fr: return "livetranslate.lang.fr".localized
        case .de: return "livetranslate.lang.de".localized
        case .ru: return "livetranslate.lang.ru".localized
        case .es: return "livetranslate.lang.es".localized
        case .pt: return "livetranslate.lang.pt".localized
        case .it: return "livetranslate.lang.it".localized
        case .yue: return "livetranslate.lang.yue".localized
        case .id: return "livetranslate.lang.id".localized
        case .vi: return "livetranslate.lang.vi".localized
        case .th: return "livetranslate.lang.th".localized
        case .ar: return "livetranslate.lang.ar".localized
        case .hi: return "livetranslate.lang.hi".localized
        case .el: return "livetranslate.lang.el".localized
        case .tr: return "livetranslate.lang.tr".localized
        }
    }

    /// 기존 화면 코드와 호환하기 위해 이름은 유지하되 국기 이모티콘 대신 문자 표지를 사용한다.
    var flag: String {
        switch self {
        case .en: return "EN"
        case .zh: return "중"
        case .ja: return "일"
        case .ko: return "한"
        case .fr: return "FR"
        case .de: return "DE"
        case .ru: return "RU"
        case .es: return "ES"
        case .pt: return "PT"
        case .it: return "IT"
        case .yue: return "광"
        case .id: return "ID"
        case .vi: return "VI"
        case .th: return "TH"
        case .ar: return "AR"
        case .hi: return "HI"
        case .el: return "EL"
        case .tr: return "TR"
        }
    }

    var supportsAudioOutput: Bool {
        switch self {
        case .en, .zh, .ja, .ko, .fr, .de, .ru, .es, .pt, .it, .yue:
            return true
        case .id, .vi, .th, .ar, .hi, .el, .tr:
            return false
        }
    }

    static var targetLanguages: [TranslateLanguage] {
        allCases.filter(\.supportsAudioOutput)
    }

    static var sourceLanguages: [TranslateLanguage] {
        allCases
    }
}

// MARK: - 번역 음성

enum TranslateVoice: String, CaseIterable, Codable, Identifiable {
    case cherry = "Cherry"
    case nofish = "Nofish"
    case jada = "Jada"
    case dylan = "Dylan"
    case sunny = "Sunny"
    case peter = "Peter"
    case kiki = "Kiki"
    case eric = "Eric"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cherry: return "livetranslate.voice.cherry".localized
        case .nofish: return "livetranslate.voice.nofish".localized
        case .jada: return "livetranslate.voice.jada".localized
        case .dylan: return "livetranslate.voice.dylan".localized
        case .sunny: return "livetranslate.voice.sunny".localized
        case .peter: return "livetranslate.voice.peter".localized
        case .kiki: return "livetranslate.voice.kiki".localized
        case .eric: return "livetranslate.voice.eric".localized
        }
    }

    var description: String {
        switch self {
        case .cherry: return "livetranslate.voice.cherry.desc".localized
        case .nofish: return "livetranslate.voice.nofish.desc".localized
        case .jada: return "livetranslate.voice.jada.desc".localized
        case .dylan: return "livetranslate.voice.dylan.desc".localized
        case .sunny: return "livetranslate.voice.sunny.desc".localized
        case .peter: return "livetranslate.voice.peter.desc".localized
        case .kiki: return "livetranslate.voice.kiki.desc".localized
        case .eric: return "livetranslate.voice.eric.desc".localized
        }
    }

    var supportedLanguages: [TranslateLanguage] {
        switch self {
        case .cherry, .nofish:
            return [.zh, .en, .fr, .de, .ru, .it, .es, .pt, .ja, .ko]
        case .jada, .dylan, .sunny, .peter, .eric:
            return [.zh]
        case .kiki:
            return [.yue]
        }
    }

    func supports(language: TranslateLanguage) -> Bool {
        supportedLanguages.contains(language)
    }
}

// MARK: - 번역 기록

struct TranslateRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let sourceLanguage: TranslateLanguage
    let targetLanguage: TranslateLanguage
    let originalText: String
    let translatedText: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        originalText: String,
        translatedText: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.originalText = originalText
        self.translatedText = translatedText
    }
}

// MARK: - WebSocket 이벤트

enum TranslateClientEvent: String {
    case sessionUpdate = "session.update"
    case inputAudioBufferAppend = "input_audio_buffer.append"
    case inputImageBufferAppend = "input_image_buffer.append"
}

enum TranslateServerEvent: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case responseCreated = "response.created"
    case responseOutputItemAdded = "response.output_item.added"
    case responseContentPartAdded = "response.content_part.added"
    case responseAudioTranscriptText = "response.audio_transcript.text"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseTextDone = "response.text.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseContentPartDone = "response.content_part.done"
    case responseOutputItemDone = "response.output_item.done"
    case responseDone = "response.done"
    case error
}

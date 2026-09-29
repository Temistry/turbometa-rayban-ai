/*
 * Google Gemini Live 기반 실시간 번역 언어, 음성, 기록 모델
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

    /// 기존 UI와 호환하기 위한 짧은 문자 표지다.
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

    /// Gemini Live의 네이티브 음성은 세션 지시에 맞춰 출력 언어를 자동 선택한다.
    var supportsAudioOutput: Bool { true }

    static var targetLanguages: [TranslateLanguage] { allCases }
    static var sourceLanguages: [TranslateLanguage] { allCases }
}

// MARK: - Gemini voice

enum TranslateVoice: String, CaseIterable, Codable, Identifiable {
    case aoede = "Aoede"
    case kore = "Kore"
    case puck = "Puck"
    case charon = "Charon"
    case fenrir = "Fenrir"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .aoede: return "부드럽고 자연스러운 음성"
        case .kore: return "차분하고 또렷한 음성"
        case .puck: return "밝고 경쾌한 음성"
        case .charon: return "안정감 있는 낮은 음성"
        case .fenrir: return "힘 있고 선명한 음성"
        }
    }

    func supports(language: TranslateLanguage) -> Bool { true }
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

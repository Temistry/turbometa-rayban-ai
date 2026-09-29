/*
 * Language Manager
 * 한국어 전용 언어 관리자
 */

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable {
    case korean = "ko"

    var displayName: String { "한국어" }
    var locale: Locale { Locale(identifier: "ko-KR") }
}

@MainActor
class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    private let languageKey = "app_language"

    @Published var currentLanguage: AppLanguage = .korean {
        didSet {
            UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: languageKey)
            updateBundle()
        }
    }

    // 앱에 포함된 한국어 리소스 번들을 사용한다.
    nonisolated(unsafe) static var currentBundle: Bundle = .main

    private init() {
        UserDefaults.standard.set(AppLanguage.korean.rawValue, forKey: languageKey)
        self.currentLanguage = .korean
        updateBundle()
    }

    private func updateBundle() {
        if let path = Bundle.main.path(forResource: "ko", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            LanguageManager.currentBundle = bundle
        } else {
            LanguageManager.currentBundle = .main
        }
    }

    func localizedString(_ key: String) -> String {
        LanguageManager.currentBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    func localizedString(_ key: String, _ args: CVarArg...) -> String {
        let format = LanguageManager.currentBundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, arguments: args)
    }

    var isChinese: Bool { false }
    var apiLanguageCode: String { "Korean" }

    // Qwen 음성 모델용 기본값. 서버 음성 지원 여부와 무관하게 시스템 TTS는 ko-KR로 고정한다.
    var ttsVoice: String { "Cherry" }

    nonisolated static var staticIsChinese: Bool { false }
    nonisolated static var staticApiLanguageCode: String { "Korean" }
    nonisolated static var staticTtsVoice: String { "Cherry" }
    nonisolated static var staticSystemVoiceLanguage: String { "ko-KR" }
}

extension String {
    var localized: String {
        LanguageManager.currentBundle.localizedString(forKey: self, value: nil, table: nil)
    }

    func localized(_ args: CVarArg...) -> String {
        let format = LanguageManager.currentBundle.localizedString(forKey: self, value: nil, table: nil)
        return String(format: format, arguments: args)
    }
}

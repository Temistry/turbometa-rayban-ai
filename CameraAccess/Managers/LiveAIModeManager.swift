/*
 * Live AI 대화 모드와 시스템 프롬프트를 관리한다.
 */

import Foundation
import SwiftUI

final class LiveAIModeManager: ObservableObject {
    static let shared = LiveAIModeManager()

    private let userDefaults = UserDefaults.standard
    private let modeKey = "liveAIMode"
    private let customPromptKey = "liveAICustomPrompt"
    private let translateTargetLanguageKey = "liveAITranslateTargetLanguage"

    @Published var currentMode: LiveAIMode {
        didSet {
            userDefaults.set(currentMode.rawValue, forKey: modeKey)
            print("[LiveAIMode][INFO] 대화 모드 변경 mode=\(currentMode.rawValue) name=\(currentMode.displayName)")
        }
    }

    @Published var customPrompt: String {
        didSet {
            userDefaults.set(customPrompt, forKey: customPromptKey)
        }
    }

    @Published var translateTargetLanguage: String {
        didSet {
            userDefaults.set(translateTargetLanguage, forKey: translateTargetLanguageKey)
        }
    }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("ko-KR", "한국어"),
        ("en-US", "영어"),
        ("ja-JP", "일본어"),
        ("zh-CN", "중국어"),
        ("fr-FR", "프랑스어"),
        ("de-DE", "독일어"),
        ("es-ES", "스페인어"),
        ("it-IT", "이탈리아어"),
        ("pt-BR", "포르투갈어"),
        ("ru-RU", "러시아어")
    ]

    private init() {
        if let savedMode = userDefaults.string(forKey: modeKey),
           let mode = LiveAIMode(rawValue: savedMode) {
            self.currentMode = mode
        } else {
            self.currentMode = .standard
        }

        self.customPrompt = userDefaults.string(forKey: customPromptKey)
            ?? "항상 한국어로 간결하고 정확하게 답하는 스마트 안경 AI 도우미로 행동해 주세요."

        let savedLanguage = userDefaults.string(forKey: translateTargetLanguageKey)
        if let savedLanguage,
           Self.supportedLanguages.contains(where: { $0.code == savedLanguage }) {
            self.translateTargetLanguage = savedLanguage
        } else {
            // 이전 버전은 "Korean"이라는 API 표시값을 저장할 수 있었다. 실제 언어 코드는 ko-KR이다.
            self.translateTargetLanguage = "ko-KR"
            userDefaults.set("ko-KR", forKey: translateTargetLanguageKey)
        }
    }

    func getSystemPrompt() -> String {
        getSystemPrompt(for: currentMode)
    }

    func getSystemPrompt(for mode: LiveAIMode) -> String {
        switch mode {
        case .custom:
            return customPrompt
        case .translate:
            return getTranslatePrompt()
        default:
            return mode.systemPrompt
        }
    }

    private func getTranslatePrompt() -> String {
        let targetLanguageName = Self.supportedLanguages.first {
            $0.code == translateTargetLanguage
        }?.name ?? "한국어"

        return "prompt.liveai.translate".localized
            .replacingOccurrences(of: "{LANGUAGE}", with: targetLanguageName)
    }

    func setMode(_ mode: LiveAIMode) {
        currentMode = mode
    }

    func setCustomPrompt(_ prompt: String) {
        customPrompt = prompt
    }

    func setTranslateTargetLanguage(_ languageCode: String) {
        guard Self.supportedLanguages.contains(where: { $0.code == languageCode }) else {
            print("[LiveAIMode][WARN] 지원하지 않는 번역 언어 코드 무시 code=\(languageCode)")
            return
        }
        translateTargetLanguage = languageCode
    }

    static var staticCurrentMode: LiveAIMode {
        shared.currentMode
    }

    static var staticSystemPrompt: String {
        shared.getSystemPrompt()
    }

    static var staticAutoSendImageOnSpeech: Bool {
        shared.currentMode.autoSendImageOnSpeech
    }
}

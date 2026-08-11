import Foundation
import SwiftUI

class QuickVisionModeManager: ObservableObject {
    static let shared = QuickVisionModeManager()

    private let userDefaults = UserDefaults.standard
    private let modeKey = "quickVisionMode"
    private let customPromptKey = "quickVisionCustomPrompt"
    private let translateTargetLanguageKey = "quickVisionTranslateTargetLanguage"

    @Published var currentMode: QuickVisionMode {
        didSet { userDefaults.set(currentMode.rawValue, forKey: modeKey) }
    }
    @Published var customPrompt: String {
        didSet { userDefaults.set(customPrompt, forKey: customPromptKey) }
    }
    @Published var translateTargetLanguage: String {
        didSet { userDefaults.set(translateTargetLanguage, forKey: translateTargetLanguageKey) }
    }

    static let supportedLanguages: [(code: String, name: String)] = [
        ("ko-KR", "한국어"), ("en-US", "영어"), ("ja-JP", "일본어"),
        ("zh-CN", "중국어"), ("fr-FR", "프랑스어"), ("de-DE", "독일어"),
        ("es-ES", "스페인어"), ("it-IT", "이탈리아어"),
        ("pt-BR", "포르투갈어"), ("ru-RU", "러시아어")
    ]

    private init() {
        if let savedMode = userDefaults.string(forKey: modeKey), let mode = QuickVisionMode(rawValue: savedMode) {
            self.currentMode = mode
        } else {
            self.currentMode = .standard
        }
        self.customPrompt = userDefaults.string(forKey: customPromptKey) ?? "눈앞의 장면을 핵심만 짧고 자연스러운 한국어로 설명해줘. 음성으로 듣기 좋게 1~2문장으로 답해줘."
        self.translateTargetLanguage = userDefaults.string(forKey: translateTargetLanguageKey) ?? "ko-KR"
    }

    func getPrompt() -> String { getPrompt(for: currentMode) }

    func getPrompt(for mode: QuickVisionMode) -> String {
        switch mode {
        case .standard:
            return "너는 스마트 안경 AI 도우미야. 반드시 한국어로 짧고 자연스럽게 답해. 먼저 화면에 손가락이나 손이 분명하게 가리키는 대상·영역·글자가 있으면 그 대상을 가장 먼저 설명해. 가리키는 손이 없거나 대상이 불확실하면 손가락을 추측하지 말고 현재 장면의 중요한 내용을 설명해. 보이는 한국어 이외의 글자는 빠짐없이 원문을 읽고 자연스러운 한국어 번역을 덧붙여. 응답은 '대상 또는 장면: ...'으로 시작하고, 외국어가 있을 때만 '보이는 외국어와 번역: 원문 — 번역'을 이어서 말해. 음성으로 듣기 좋게 2~3문장으로 간결히 답하고 '이미지에서' 같은 표현은 쓰지 마."
        case .health:
            return "사진 속 음식이나 음료의 영양 균형, 당·염분·지방, 첨가물과 건강상 주의점을 분석하고 실용적인 조언을 한국어로 짧게 알려줘."
        case .blind:
            return "시각 보조를 위해 눈앞의 사람과 사물, 거리와 방향, 장애물이나 위험 요소를 우선순위대로 명확한 한국어로 설명해줘."
        case .reading:
            return "눈앞에 보이는 글자를 읽기 순서대로 정확히 인식해서 한국어로 읽어줘. 외국어라면 원문을 간단히 밝히고 의미를 한국어로 설명해줘."
        case .translate:
            return getTranslatePrompt()
        case .encyclopedia:
            return "눈앞의 사물, 건축물, 작품 또는 생물을 식별하고 이름, 종류, 배경과 흥미로운 정보를 한국어로 짧고 쉽게 설명해줘."
        case .custom:
            return customPrompt
        }
    }

    private func getTranslatePrompt() -> String {
        let target = Self.supportedLanguages.first { $0.code == translateTargetLanguage }?.name ?? "한국어"
        return "눈앞의 글자를 정확히 인식하고 \(target)(으)로 자연스럽게 번역해줘. 번역 결과를 먼저 말하고 불필요한 설명은 생략해줘."
    }

    func setMode(_ mode: QuickVisionMode) { currentMode = mode }
    func setCustomPrompt(_ prompt: String) { customPrompt = prompt }
    func setTranslateTargetLanguage(_ languageCode: String) { translateTargetLanguage = languageCode }

    static var staticCurrentMode: QuickVisionMode { shared.currentMode }
    static var staticPrompt: String { shared.getPrompt() }
}

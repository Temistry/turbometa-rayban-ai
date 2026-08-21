/*
 * Google Gemini Live 기반 실시간 번역 서비스
 *
 * 기존 Alibaba 전용 WebSocket 구현을 제거하고 GeminiLiveService를 통역 세션으로
 * 구성한다. 실제 인증값과 사용자 발화·번역 본문은 콘솔에 기록하지 않는다.
 */

import Foundation
import UIKit

final class LiveTranslateService {
    private let apiKey: String
    private let model: String

    private var sourceLanguage: TranslateLanguage = .en
    private var targetLanguage: TranslateLanguage = .ko
    private var voice: TranslateVoice = .aoede
    private var audioOutputEnabled = true
    private var geminiService: GeminiLiveService?
    private var isConnected = false

    var onConnected: (() -> Void)?
    var onOriginalText: ((String) -> Void)?
    var onTranslationText: ((String) -> Void)?
    var onTranslationDelta: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onError: ((String) -> Void)?

    init(apiKey: String, model: String = APIProviderManager.staticLiveAIModel) {
        self.apiKey = apiKey
        self.model = model
    }

    func connect() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onError?("Google Gemini API Key가 설정되지 않았습니다")
            return
        }

        if isConnected {
            print("[Translate][WARN] 이미 Gemini 번역 세션이 연결되어 있어 중복 요청 무시")
            return
        }

        let service = GeminiLiveService(
            apiKey: apiKey,
            model: model,
            systemInstruction: translationInstruction,
            voiceName: voice.rawValue,
            audioOutputEnabled: audioOutputEnabled
        )
        geminiService = service
        configureCallbacks(for: service)

        print(
            "[Translate][INFO] Gemini 번역 연결 시작 model=\(model) "
            + "source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue) "
            + "voice=\(voice.rawValue) audio=\(audioOutputEnabled)"
        )
        service.connect()
    }

    func disconnect() {
        isConnected = false
        geminiService?.disconnect()
        geminiService = nil
        print("[Translate][INFO] Gemini 번역 연결 종료")
    }

    func updateSettings(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        voice: TranslateVoice,
        audioEnabled: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voice = voice
        self.audioOutputEnabled = audioEnabled

        if isConnected {
            print("[Translate][INFO] 번역 설정 변경은 다음 연결부터 적용")
        }
    }

    func startRecording(usePhoneMic: Bool = false) {
        guard isConnected else {
            onError?("번역 서버에 연결된 뒤 녹음을 시작하세요")
            return
        }

        geminiService?.startRecording(usePhoneMic: usePhoneMic)
        print("[Translate][INFO] Gemini 번역 녹음 시작 microphone=\(usePhoneMic ? "iphone" : "bluetooth")")
    }

    func stopRecording() {
        geminiService?.stopRecording()
        print("[Translate][INFO] Gemini 번역 녹음 중지")
    }

    func sendImageFrame(_ image: UIImage) {
        geminiService?.sendImageInput(image)
    }

    private var translationInstruction: String {
        Self.translationInstruction(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    static func translationInstruction(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage
    ) -> String {
        """
        당신은 스마트 안경용 실시간 통역사입니다.
        입력 언어는 \(sourceLanguage.displayName), 출력 언어는 \(targetLanguage.displayName)입니다.
        사용자의 발화를 의미와 말투를 유지해 자연스럽게 번역하세요.
        답변에는 번역 결과만 포함하고 설명, 인사말, 원문 반복을 추가하지 마세요.
        화면 이미지가 함께 들어오면 고유명사와 문맥을 이해하는 보조 자료로만 사용하세요.
        반드시 \(targetLanguage.displayName)로 답하세요.
        """
    }

    private func configureCallbacks(for service: GeminiLiveService) {
        service.onConnected = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.onConnected?()
        }

        service.onUserTranscript = { [weak self] text in
            guard !text.isEmpty else { return }
            self?.onOriginalText?(text)
        }

        service.onTranscriptDelta = { [weak self] delta in
            self?.onTranslationDelta?(delta)
        }

        service.onTranscriptDone = { [weak self] text in
            guard !text.isEmpty else { return }
            self?.onTranslationText?(text)
        }

        service.onAudioDelta = { [weak self] data in
            self?.onAudioDelta?(data)
        }

        service.onAudioDone = { [weak self] in
            self?.onAudioDone?()
        }

        service.onError = { [weak self] message in
            self?.isConnected = false
            self?.onError?(message)
        }
    }
}

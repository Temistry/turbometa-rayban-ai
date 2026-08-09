/*
 * 실시간 번역 상태 관리자
 */

import Foundation
import SwiftUI
import UIKit

@MainActor
final class LiveTranslateViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isRecording = false

    @Published var currentTranslation = ""
    @Published var currentOriginal = ""
    @Published var streamingTranslation = ""
    @Published var translationHistory: [TranslateRecord] = []

    @Published var errorMessage: String?
    @Published var showError = false

    @Published var sourceLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(sourceLanguage.rawValue, forKey: "translate_source_language")
            updateServiceSettings()
        }
    }

    @Published var targetLanguage: TranslateLanguage {
        didSet {
            UserDefaults.standard.set(targetLanguage.rawValue, forKey: "translate_target_language")
            updateServiceSettings()
        }
    }

    @Published var selectedVoice: TranslateVoice {
        didSet {
            UserDefaults.standard.set(selectedVoice.rawValue, forKey: "translate_voice")
            updateServiceSettings()
        }
    }

    @Published var audioOutputEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioOutputEnabled, forKey: "translate_audio_enabled")
            updateServiceSettings()
        }
    }

    @Published var imageEnhanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(imageEnhanceEnabled, forKey: "translate_image_enhance")
        }
    }

    @Published var usePhoneMic: Bool {
        didSet {
            UserDefaults.standard.set(usePhoneMic, forKey: "translate_use_phone_mic")
        }
    }

    var currentVideoFrame: UIImage?

    private var translateService: LiveTranslateService?
    private var imageTimer: Timer?
    private var isDisconnecting = false

    init() {
        let savedSource = UserDefaults.standard.string(forKey: "translate_source_language") ?? TranslateLanguage.en.rawValue
        sourceLanguage = TranslateLanguage(rawValue: savedSource) ?? .en

        let savedTarget = UserDefaults.standard.string(forKey: "translate_target_language") ?? TranslateLanguage.ko.rawValue
        targetLanguage = TranslateLanguage(rawValue: savedTarget) ?? .ko

        let savedVoice = UserDefaults.standard.string(forKey: "translate_voice") ?? TranslateVoice.cherry.rawValue
        selectedVoice = TranslateVoice(rawValue: savedVoice) ?? .cherry

        audioOutputEnabled = UserDefaults.standard.object(forKey: "translate_audio_enabled") as? Bool ?? true
        imageEnhanceEnabled = UserDefaults.standard.object(forKey: "translate_image_enhance") as? Bool ?? false
        usePhoneMic = UserDefaults.standard.object(forKey: "translate_use_phone_mic") as? Bool ?? false

        if UserDefaults.standard.object(forKey: "translate_target_language") == nil {
            targetLanguage = .ko
            UserDefaults.standard.set(TranslateLanguage.ko.rawValue, forKey: "translate_target_language")
        }

        ensureVoiceSupportsTargetLanguage()
        print("[TranslateVM][INFO] 초기화 source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue) voice=\(selectedVoice.rawValue)")
    }

    func connect() {
        // 실시간 번역은 Live AI 제공자 선택과 무관하게 Alibaba 전용 모델을 사용한다.
        let endpoint = APIProviderManager.staticAlibabaEndpoint
        let apiKey = APIKeyManager.shared.getAPIKey(for: .alibaba, endpoint: endpoint) ?? ""
        guard !apiKey.isEmpty else {
            presentError("Alibaba \(endpoint.displayName) API Key를 먼저 설정하세요")
            return
        }

        isDisconnecting = false
        translateService = LiveTranslateService(apiKey: apiKey)
        setupCallbacks()
        updateServiceSettings()
        print("[TranslateVM][INFO] 연결 요청 endpoint=\(endpoint.rawValue) source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue) voice=\(selectedVoice.rawValue)")
        translateService?.connect()
    }

    func disconnect() {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        stopImageTimer()
        translateService?.disconnect()
        translateService = nil
        isConnected = false
        isRecording = false
        print("[TranslateVM][INFO] 연결 종료")
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard isConnected else {
            presentError("번역 서버에 연결된 뒤 녹음을 시작하세요")
            return
        }
        translateService?.startRecording(usePhoneMic: usePhoneMic)
        isRecording = true
        print("[TranslateVM][INFO] 녹음 시작 microphone=\(usePhoneMic ? "iphone" : "glasses")")

        if imageEnhanceEnabled { startImageTimer() }
    }

    func stopRecording() {
        translateService?.stopRecording()
        isRecording = false
        stopImageTimer()
        print("[TranslateVM][INFO] 녹음 중지 translationLength=\(currentTranslation.count)")

        if !currentTranslation.isEmpty {
            translationHistory.insert(
                TranslateRecord(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    originalText: currentOriginal,
                    translatedText: currentTranslation
                ),
                at: 0
            )
            if translationHistory.count > 50 {
                translationHistory = Array(translationHistory.prefix(50))
            }
        }
    }

    func swapLanguages() {
        guard sourceLanguage.supportsAudioOutput && targetLanguage.supportsAudioOutput else {
            presentError("livetranslate.error.cannotSwap".localized)
            return
        }

        let previousSource = sourceLanguage
        sourceLanguage = targetLanguage
        targetLanguage = previousSource
        ensureVoiceSupportsTargetLanguage()
        clearTranslation()
        print("[TranslateVM][INFO] 언어 교환 source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue)")
    }

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    private func setupCallbacks() {
        translateService?.onConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isDisconnecting else { return }
                self.isConnected = true
                print("[TranslateVM][INFO] 번역 세션 연결 완료")
            }
        }

        translateService?.onTranslationDelta = { [weak self] delta in
            DispatchQueue.main.async {
                self?.streamingTranslation += delta
            }
        }

        translateService?.onTranslationText = { [weak self] text in
            DispatchQueue.main.async {
                self?.currentTranslation = text
                self?.streamingTranslation = ""
                print("[TranslateVM][INFO] 번역 문장 완료 length=\(text.count)")
            }
        }

        translateService?.onAudioDone = {
            DispatchQueue.main.async {
                print("[TranslateVM][INFO] 번역 음성 재생 완료")
            }
        }

        translateService?.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isDisconnecting {
                    print("[TranslateVM][INFO] 종료 중 오류 콜백 무시 description=\(error)")
                    return
                }
                self.presentError(error)
            }
        }
    }

    private func updateServiceSettings() {
        ensureVoiceSupportsTargetLanguage()
        translateService?.updateSettings(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            voice: selectedVoice,
            audioEnabled: audioOutputEnabled
        )
    }

    private func ensureVoiceSupportsTargetLanguage() {
        if !selectedVoice.supports(language: targetLanguage) {
            selectedVoice = .cherry
        }
    }

    private func startImageTimer() {
        stopImageTimer()
        imageTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendCurrentFrame()
            }
        }
    }

    private func stopImageTimer() {
        imageTimer?.invalidate()
        imageTimer = nil
    }

    private func sendCurrentFrame() {
        guard imageEnhanceEnabled, let currentVideoFrame else { return }
        translateService?.sendImageFrame(currentVideoFrame)
    }

    func clearTranslation() {
        currentTranslation = ""
        streamingTranslation = ""
        currentOriginal = ""
    }

    func clearHistory() {
        translationHistory.removeAll()
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
        print("[TranslateVM][ERROR] 사용자 오류 표시 description=\(message)")
    }
}

/*
 * 실시간 멀티모달 대화 상태 관리자
 * Alibaba Qwen Omni와 Google Gemini Live를 같은 한국어 UI로 연결한다.
 */

import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class OmniRealtimeViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var currentTranscript = ""
    @Published var conversationHistory: [ConversationMessage] = []
    @Published var errorMessage: String?
    @Published var showError = false

    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private let provider: LiveAIProvider
    private let apiKey: String

    private var currentVideoFrame: UIImage?
    private var isImageSendingEnabled = false
    private var isDisconnecting = false

    init(apiKey: String) {
        self.apiKey = apiKey
        self.provider = APIProviderManager.staticLiveAIProvider

        switch provider {
        case .alibaba:
            omniService = OmniRealtimeService(apiKey: apiKey)
        case .google:
            geminiService = GeminiLiveService(
                apiKey: apiKey,
                model: APIProviderManager.staticLiveAIModel
            )
        }

        setupCallbacks()
        print("[LiveAIVM][INFO] 초기화 provider=\(provider.displayName) apiKeyConfigured=\(!apiKey.isEmpty)")
    }

    private func setupCallbacks() {
        switch provider {
        case .alibaba:
            setupOmniCallbacks()
        case .google:
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isDisconnecting else { return }
                self.isConnected = true
                print("[LiveAIVM][INFO] Alibaba 세션 연결 완료")
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.isImageSendingEnabled = true
                print("[LiveAIVM][INFO] 음성 감지 시 안경 화면 전송 활성화")
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isImageSendingEnabled, let frame = self.currentVideoFrame {
                    print("[LiveAIVM][INFO] 사용자 발화 감지, 현재 화면 전송 size=\(frame.size.width)x\(frame.size.height)")
                    self.omniService?.sendImageAppend(frame)
                }
            }
        }

        omniService.onTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                self?.currentTranscript += delta
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self, !userText.isEmpty else { return }
                self.conversationHistory.append(.init(role: .user, content: userText))
                print("[LiveAIVM][INFO] 사용자 자막 저장 length=\(userText.count)")
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                self?.finishAssistantTranscript(fullText)
            }
        }

        omniService.onAudioDelta = { [weak self] _ in
            Task { @MainActor in self?.isSpeaking = true }
        }

        omniService.onAudioDone = { [weak self] in
            Task { @MainActor in self?.isSpeaking = false }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.presentError(error)
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isDisconnecting else { return }
                self.isConnected = true
                print("[LiveAIVM][INFO] Gemini 세션 연결 완료")
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.isImageSendingEnabled = true
                print("[LiveAIVM][INFO] Gemini 화면 전송 활성화")
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isImageSendingEnabled, let frame = self.currentVideoFrame {
                    print("[LiveAIVM][INFO] Gemini 사용자 발화 감지, 현재 화면 전송 size=\(frame.size.width)x\(frame.size.height)")
                    self.geminiService?.sendImageInput(frame)
                }
            }
        }

        geminiService.onTranscriptDelta = { [weak self] delta in
            Task { @MainActor in
                self?.currentTranscript += delta
            }
        }

        geminiService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self, !userText.isEmpty else { return }
                self.conversationHistory.append(.init(role: .user, content: userText))
                print("[LiveAIVM][INFO] Gemini 사용자 자막 저장 length=\(userText.count)")
            }
        }

        geminiService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                self?.finishAssistantTranscript(fullText)
            }
        }

        geminiService.onAudioDelta = { [weak self] _ in
            Task { @MainActor in self?.isSpeaking = true }
        }

        geminiService.onAudioDone = { [weak self] in
            Task { @MainActor in self?.isSpeaking = false }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor in
                self?.presentError(error)
            }
        }
    }

    private func finishAssistantTranscript(_ fullText: String) {
        let textToSave = fullText.isEmpty ? currentTranscript : fullText
        guard !textToSave.isEmpty else {
            print("[LiveAIVM][WARN] AI 자막이 비어 있어 저장 생략")
            currentTranscript = ""
            return
        }

        conversationHistory.append(.init(role: .assistant, content: textToSave))
        currentTranscript = ""
        print("[LiveAIVM][INFO] AI 자막 저장 length=\(textToSave.count)")
    }

    private func presentError(_ error: String) {
        guard !isDisconnecting else {
            print("[LiveAIVM][INFO] 종료 중 오류 콜백 무시 description=\(error)")
            return
        }

        errorMessage = error
        showError = true
        isConnected = false
        isRecording = false
        isSpeaking = false
        print("[LiveAIVM][ERROR] 사용자 오류 표시 description=\(error)")
    }

    // MARK: - Connection

    func connect() {
        guard !apiKey.isEmpty else {
            presentError("\(provider.displayName) API Key가 설정되지 않았습니다")
            return
        }

        isDisconnecting = false
        print("[LiveAIVM][INFO] 연결 요청 provider=\(provider.displayName)")
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    func disconnect() {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        print("[LiveAIVM][INFO] 연결 종료 provider=\(provider.displayName)")

        saveConversation()
        stopRecording()

        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        isConnected = false
        isSpeaking = false
        isImageSendingEnabled = false
    }

    private func saveConversation() {
        guard !conversationHistory.isEmpty else {
            print("[LiveAIVM][INFO] 저장할 대화 없음")
            return
        }

        let model = provider == .alibaba
            ? "qwen3-omni-flash-realtime"
            : APIProviderManager.staticLiveAIModel

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: model,
            language: "ko-KR"
        )
        ConversationStorage.shared.saveConversation(record)
        print("[LiveAIVM][INFO] 대화 저장 messages=\(conversationHistory.count) model=\(model) language=ko-KR")
    }

    // MARK: - Recording

    func startRecording() {
        guard isConnected else {
            presentError("AI 서버에 연결된 뒤 마이크를 시작하세요")
            return
        }
        guard !isRecording else { return }

        print("[LiveAIVM][INFO] 마이크 시작 provider=\(provider.displayName)")
        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        print("[LiveAIVM][INFO] 마이크 중지 provider=\(provider.displayName)")

        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }
        isRecording = false
    }

    func updateVideoFrame(_ frame: UIImage) {
        currentVideoFrame = frame
    }

    func sendMessage() {
        omniService?.commitAudioBuffer()
    }

    func dismissError() {
        showError = false
        errorMessage = nil
    }

    nonisolated deinit {
        Task { @MainActor [weak omniService, weak geminiService] in
            omniService?.disconnect()
            geminiService?.disconnect()
        }
    }
}

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()

    enum MessageRole {
        case user
        case assistant
    }
}

/*
 * Live AI 관리자
 * Siri와 단축어에서 앱을 열어 실시간 AI 세션을 시작하고 관리한다.
 */

import Foundation
import SwiftUI
import AVFoundation

// MARK: - Live AI Manager

@MainActor
class LiveAIManager: ObservableObject {
    static let shared = LiveAIManager()

    @Published var isRunning = false
    @Published var isConnected = false
    @Published var errorMessage: String?

    // 의존 객체
    private(set) var streamViewModel: StreamSessionViewModel?
    private var omniService: OmniRealtimeService?
    private var geminiService: GeminiLiveService?
    private var provider: LiveAIProvider = .alibaba

    // 영상 프레임
    private var currentVideoFrame: UIImage?
    private var isImageSendingEnabled = false
    private var frameUpdateTimer: Timer?

    // 대화 기록
    private var conversationHistory: [ConversationMessage] = []

    // 음성 출력
    private let tts = TTSService.shared

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiveAITrigger(_:)),
            name: .liveAITriggered,
            object: nil
        )
    }

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        streamViewModel = viewModel
        print("[LiveAIManager][INFO] StreamViewModel 연결 완료 hasActiveDevice=\(viewModel.hasActiveDevice) streamStatus=\(viewModel.streamingStatus)")
    }

    @objc private func handleLiveAITrigger(_ notification: Notification) {
        Task { @MainActor in
            await startLiveAISession()
        }
    }

    // MARK: - Start Session

    func startLiveAISession() async {
        guard !isRunning else {
            print("[LiveAIManager][WARN] 이미 실행 중이므로 중복 시작 요청을 무시합니다")
            return
        }

        guard let streamViewModel else {
            let message = "Live AI가 아직 준비되지 않았습니다. 앱을 연 뒤 다시 시도하세요"
            errorMessage = message
            print("[LiveAIManager][ERROR] StreamViewModel이 설정되지 않았습니다")
            tts.speak(message)
            return
        }

        let apiKey = APIProviderManager.staticLiveAIAPIKey
        guard !apiKey.isEmpty else {
            let message = "설정에서 API Key를 먼저 등록하세요"
            errorMessage = message
            print("[LiveAIManager][ERROR] Live AI API Key가 설정되지 않았습니다 provider=\(APIProviderManager.staticLiveAIProvider.displayName)")
            tts.speak(message)
            return
        }

        isRunning = true
        errorMessage = nil
        conversationHistory = []
        provider = APIProviderManager.staticLiveAIProvider

        print("[LiveAIManager][INFO] Live AI 세션 시작 provider=\(provider.displayName)")

        do {
            guard streamViewModel.hasActiveDevice else {
                print("[LiveAIManager][ERROR] 연결된 안경이 없습니다")
                throw LiveAIError.noDevice
            }

            if streamViewModel.streamingStatus != .streaming {
                print("[LiveAIManager][INFO] 영상 스트림 시작 요청")
                await streamViewModel.handleStartStreaming()

                let streamReady = await waitForCondition(timeout: 5.0) {
                    streamViewModel.streamingStatus == .streaming
                }

                guard streamReady else {
                    print("[LiveAIManager][ERROR] 영상 스트림 시작 시간 초과 status=\(streamViewModel.streamingStatus)")
                    throw LiveAIError.streamNotReady
                }
            }

            try configureAudioSessionForBackground()
            initializeService(apiKey: apiKey)

            print("[LiveAIManager][INFO] AI 서비스 연결 요청 provider=\(provider.displayName)")
            connectService()

            let connected = await waitForCondition(timeout: 10.0) {
                self.isConnected
            }

            guard connected else {
                print("[LiveAIManager][ERROR] AI 서비스 연결 시간 초과 provider=\(provider.displayName)")
                throw LiveAIError.connectionFailed
            }

            startFrameUpdateTimer()
            print("[LiveAIManager][INFO] 영상 프레임 갱신 타이머 시작")

            // 안내 음성을 재생하면 녹음 세션과 충돌할 수 있으므로 곧바로 녹음을 시작한다.
            startRecording()
            print("[LiveAIManager][INFO] Live AI 세션 시작 완료")
        } catch let error as LiveAIError {
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            print("[LiveAIManager][ERROR] 세션 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            await stopSession()
        } catch {
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            print("[LiveAIManager][ERROR] 예상하지 못한 세션 오류 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            await stopSession()
        }
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSessionForBackground() throws {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            print("[LiveAIManager][AUDIO] 기존 오디오 세션 비활성화 완료")
        } catch {
            let nsError = error as NSError
            print("[LiveAIManager][WARN] 기존 오디오 세션 비활성화 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }

        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try audioSession.setActive(true)

        let inputs = audioSession.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        let outputs = audioSession.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        print("[LiveAIManager][AUDIO] 백그라운드 오디오 세션 설정 완료 category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) sampleRate=\(audioSession.sampleRate) inputs=[\(inputs)] outputs=[\(outputs)]")
    }

    // MARK: - Initialize Service

    private func initializeService(apiKey: String) {
        switch provider {
        case .alibaba:
            omniService = OmniRealtimeService(apiKey: apiKey)
            setupOmniCallbacks()
        case .google:
            geminiService = GeminiLiveService(
                apiKey: apiKey,
                model: APIProviderManager.staticLiveAIModel
            )
            setupGeminiCallbacks()
        }
    }

    private func setupOmniCallbacks() {
        guard let omniService else { return }

        omniService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("[LiveAIManager][INFO] Alibaba Omni 연결 완료")
            }
        }

        omniService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("[LiveAIManager][INFO] 첫 오디오 전송 완료. 화면 전송을 활성화합니다")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                }
            }
        }

        omniService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("[LiveAIManager][INFO] 사용자 발화 감지. 현재 영상 프레임 전송 size=\(frame.size.width)x\(frame.size.height)")
                    strongSelf.omniService?.sendImageAppend(frame)
                }
            }
        }

        omniService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self else { return }
                // 대화 원문은 개인정보가 될 수 있으므로 개발자 로그에는 길이만 남긴다.
                print("[LiveAIManager][INFO] 사용자 음성 인식 완료 textLength=\(userText.count)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        omniService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self, !fullText.isEmpty else { return }
                print("[LiveAIManager][INFO] AI 응답 완료 textLength=\(fullText.count)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        omniService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("[LiveAIManager][ERROR] Alibaba Omni 오류 description=\(error)")
            }
        }
    }

    private func setupGeminiCallbacks() {
        guard let geminiService else { return }

        geminiService.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                print("[LiveAIManager][INFO] Gemini Live 연결 완료")
            }
        }

        geminiService.onFirstAudioSent = { [weak self] in
            Task { @MainActor in
                print("[LiveAIManager][INFO] 첫 오디오 전송 완료. 화면 전송을 활성화합니다")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.isImageSendingEnabled = true
                }
            }
        }

        geminiService.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                if let strongSelf = self,
                   strongSelf.isImageSendingEnabled,
                   let frame = strongSelf.currentVideoFrame {
                    print("[LiveAIManager][INFO] 사용자 발화 감지. 현재 영상 프레임 전송 size=\(frame.size.width)x\(frame.size.height)")
                    strongSelf.geminiService?.sendImageInput(frame)
                }
            }
        }

        geminiService.onUserTranscript = { [weak self] userText in
            Task { @MainActor in
                guard let self else { return }
                print("[LiveAIManager][INFO] 사용자 음성 인식 완료 textLength=\(userText.count)")
                self.conversationHistory.append(
                    ConversationMessage(role: .user, content: userText)
                )
            }
        }

        geminiService.onTranscriptDone = { [weak self] fullText in
            Task { @MainActor in
                guard let self, !fullText.isEmpty else { return }
                print("[LiveAIManager][INFO] AI 응답 완료 textLength=\(fullText.count)")
                self.conversationHistory.append(
                    ConversationMessage(role: .assistant, content: fullText)
                )
            }
        }

        geminiService.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error
                print("[LiveAIManager][ERROR] Gemini Live 오류 description=\(error)")
            }
        }
    }

    // MARK: - Connection

    private func connectService() {
        switch provider {
        case .alibaba:
            omniService?.connect()
        case .google:
            geminiService?.connect()
        }
    }

    private func startRecording() {
        print("[LiveAIManager][AUDIO] 녹음 시작 provider=\(provider.displayName)")
        switch provider {
        case .alibaba:
            omniService?.startRecording()
        case .google:
            geminiService?.startRecording()
        }
    }

    private func stopRecording() {
        print("[LiveAIManager][AUDIO] 녹음 중지 provider=\(provider.displayName)")
        switch provider {
        case .alibaba:
            omniService?.stopRecording()
        case .google:
            geminiService?.stopRecording()
        }
    }

    // MARK: - Frame Update

    private func startFrameUpdateTimer() {
        frameUpdateTimer?.invalidate()
        frameUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVideoFrame()
            }
        }
    }

    private func updateVideoFrame() {
        if let frame = streamViewModel?.currentVideoFrame {
            currentVideoFrame = frame
        }
    }

    // MARK: - Stop Session

    func stopSession() async {
        guard isRunning else { return }

        print("[LiveAIManager][INFO] Live AI 세션 중지 시작")

        frameUpdateTimer?.invalidate()
        frameUpdateTimer = nil
        stopRecording()
        saveConversation()

        switch provider {
        case .alibaba:
            omniService?.disconnect()
        case .google:
            geminiService?.disconnect()
        }

        await streamViewModel?.stopSession()

        omniService = nil
        geminiService = nil
        isConnected = false
        isRunning = false
        isImageSendingEnabled = false
        currentVideoFrame = nil

        print("[LiveAIManager][INFO] Live AI 세션 중지 완료")
    }

    private func saveConversation() {
        guard !conversationHistory.isEmpty else {
            print("[LiveAIManager][INFO] 저장할 대화가 없어 기록 생성을 건너뜁니다")
            return
        }

        let aiModel: String
        switch provider {
        case .alibaba:
            aiModel = "qwen3-omni-flash-realtime"
        case .google:
            aiModel = APIProviderManager.staticLiveAIModel
        }

        let record = ConversationRecord(
            messages: conversationHistory,
            aiModel: aiModel,
            language: "ko-KR"
        )

        ConversationStorage.shared.saveConversation(record)
        print("[LiveAIManager][INFO] 대화 저장 완료 messageCount=\(conversationHistory.count) model=\(aiModel)")
    }

    private func waitForCondition(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }

    func triggerStop() {
        Task { @MainActor in
            await stopSession()
        }
    }
}

// MARK: - Live AI Error

enum LiveAIError: LocalizedError {
    case noDevice
    case streamNotReady
    case connectionFailed
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "안경이 연결되지 않았습니다. Meta View에서 먼저 안경을 페어링하세요"
        case .streamNotReady:
            return "영상 스트림을 시작하지 못했습니다. 안경 연결 상태를 확인하세요"
        case .connectionFailed:
            return "AI 서비스 연결에 실패했습니다. 네트워크 상태를 확인하세요"
        case .noAPIKey:
            return "설정에서 API Key를 먼저 등록하세요"
        }
    }
}

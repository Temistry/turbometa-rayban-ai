import AppIntents
import SwiftUI
import UIKit

// MARK: - Korean Siri/App Shortcut intents

@available(iOS 16.0, *)
struct QuickVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "이거 뭐야"
    static var description = IntentDescription("Ray-Ban Meta 안경으로 사진을 찍고 눈앞의 장면을 한국어로 설명합니다")

    // DAT SDK 카메라와 StreamViewModel 초기화가 필요하므로 앱을 열어 실행한다.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "사용자 지정 요청")
    var customPrompt: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.standard, customPrompt: customPrompt)
        return formatResult(manager)
    }
}

@available(iOS 16.0, *)
struct QuickVisionHealthIntent: AppIntent {
    static var title: LocalizedStringResource = "건강 분석"
    static var description = IntentDescription("음식이나 음료의 건강 정보를 한국어로 분석합니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.health)
        return formatResult(manager)
    }
}

@available(iOS 16.0, *)
struct QuickVisionBlindIntent: AppIntent {
    static var title: LocalizedStringResource = "주변 설명"
    static var description = IntentDescription("눈앞의 환경과 장애물, 사람과 사물의 위치를 한국어로 설명합니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.blind)
        return formatResult(manager)
    }
}

@available(iOS 16.0, *)
struct QuickVisionReadingIntent: AppIntent {
    static var title: LocalizedStringResource = "글자 읽기"
    static var description = IntentDescription("눈앞의 글자를 인식하고 한국어 음성으로 읽어줍니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.reading)
        return formatResult(manager)
    }
}

@available(iOS 16.0, *)
struct QuickVisionTranslateIntent: AppIntent {
    static var title: LocalizedStringResource = "번역하기"
    static var description = IntentDescription("눈앞의 외국어 글자를 인식하고 한국어로 번역합니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.translate)
        return formatResult(manager)
    }
}

@available(iOS 16.0, *)
struct QuickVisionEncyclopediaIntent: AppIntent {
    static var title: LocalizedStringResource = "사물 알아보기"
    static var description = IntentDescription("눈앞의 사물을 인식하고 관련 정보를 한국어로 설명합니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = QuickVisionManager.shared
        await manager.performQuickVisionWithMode(.encyclopedia)
        return formatResult(manager)
    }
}

@available(iOS 16.0, *)
@MainActor
private func formatResult(_ manager: QuickVisionManager) -> some IntentResult & ProvidesDialog {
    if let result = manager.lastResult {
        return .result(dialog: "인식 완료. \(result)")
    }

    if let error = manager.errorMessage {
        return .result(dialog: "인식에 실패했습니다. \(error)")
    }

    return .result(dialog: "인식 작업을 완료했습니다")
}

@available(iOS 16.0, *)
struct TurboMetaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickVisionIntent(),
            phrases: [
                "\(.applicationName) 이거 뭐야",
                "\(.applicationName) 이게 뭐야",
                "\(.applicationName) 눈앞에 뭐가 있어",
                "\(.applicationName) 사진 인식",
                "\(.applicationName) 퀵비전 실행"
            ],
            shortTitle: "이거 뭐야",
            systemImageName: "eye.circle.fill"
        )

        AppShortcut(
            intent: QuickVisionHealthIntent(),
            phrases: [
                "\(.applicationName) 건강 분석",
                "\(.applicationName) 이 음식 건강해",
                "\(.applicationName) 음식 분석"
            ],
            shortTitle: "건강 분석",
            systemImageName: "heart.circle.fill"
        )

        AppShortcut(
            intent: QuickVisionBlindIntent(),
            phrases: [
                "\(.applicationName) 주변 설명",
                "\(.applicationName) 주변에 뭐가 있어",
                "\(.applicationName) 앞에 뭐가 있어"
            ],
            shortTitle: "주변 설명",
            systemImageName: "figure.walk.circle.fill"
        )

        AppShortcut(
            intent: QuickVisionReadingIntent(),
            phrases: [
                "\(.applicationName) 이거 읽어줘",
                "\(.applicationName) 글자 읽기",
                "\(.applicationName) 글씨 읽어줘"
            ],
            shortTitle: "글자 읽기",
            systemImageName: "text.viewfinder"
        )

        AppShortcut(
            intent: QuickVisionTranslateIntent(),
            phrases: [
                "\(.applicationName) 이거 번역해줘",
                "\(.applicationName) 번역하기",
                "\(.applicationName) 이게 무슨 뜻이야"
            ],
            shortTitle: "번역하기",
            systemImageName: "character.bubble.fill"
        )

        AppShortcut(
            intent: QuickVisionEncyclopediaIntent(),
            phrases: [
                "\(.applicationName) 이거 알려줘",
                "\(.applicationName) 사물 알아보기",
                "\(.applicationName) 이게 뭔지 알려줘"
            ],
            shortTitle: "사물 알아보기",
            systemImageName: "books.vertical.circle.fill"
        )
    }
}

extension Notification.Name {
    static let quickVisionTriggered = Notification.Name("quickVisionTriggered")
}

// MARK: - Quick Vision orchestration

@MainActor
final class QuickVisionManager: ObservableObject {
    static let shared = QuickVisionManager()

    @Published var isProcessing = false
    @Published var lastResult: String?
    @Published var errorMessage: String?
    @Published var lastImage: UIImage?
    @Published var lastMode: QuickVisionMode = .standard

    private(set) var streamViewModel: StreamSessionViewModel?
    private let tts = TTSService.shared

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleQuickVisionTrigger(_:)),
            name: .quickVisionTriggered,
            object: nil
        )
    }

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        streamViewModel = viewModel
        print(
            "[QuickVision][INFO] StreamViewModel 연결 완료 "
            + "hasActiveDevice=\(viewModel.hasActiveDevice) streamingStatus=\(viewModel.streamingStatus)"
        )
    }

    @objc private func handleQuickVisionTrigger(_ notification: Notification) {
        let customPrompt = notification.userInfo?["customPrompt"] as? String
        let modeString = notification.userInfo?["mode"] as? String
        let mode = modeString.flatMap { QuickVisionMode(rawValue: $0) } ?? .standard
        Task { @MainActor in
            await performQuickVisionWithMode(mode, customPrompt: customPrompt)
        }
    }

    func performQuickVisionWithMode(_ mode: QuickVisionMode, customPrompt: String? = nil) async {
        let prompt = customPrompt ?? QuickVisionModeManager.shared.getPrompt(for: mode)
        let model = GeminiModelCatalog.quickVision

        guard !isProcessing else {
            let rejectedRecord = QuickVisionRecord(
                mode: mode,
                prompt: prompt,
                status: .rejected,
                errorCode: "already_processing",
                errorMessage: "이전 퀵비전 인식이 아직 진행 중입니다",
                metadata: ["source": "app", "model": model]
            )
            QuickVisionStorage.shared.upsertRecord(rejectedRecord)
            print("[QuickVision][WARN] 이미 처리 중이므로 중복 요청 기록 mode=\(mode.rawValue)")
            return
        }

        var record = QuickVisionRecord(
            mode: mode,
            prompt: prompt,
            metadata: ["source": "app", "model": model]
        )
        QuickVisionStorage.shared.upsertRecord(record)

        guard let streamViewModel else {
            let message = "이미지 인식 기능이 아직 준비되지 않았습니다. 앱을 연 뒤 다시 시도하세요"
            errorMessage = message
            record.status = .failed
            record.errorCode = "stream_unavailable"
            record.errorMessage = message
            QuickVisionStorage.shared.upsertRecord(record)
            print("[QuickVision][ERROR] StreamViewModel 없음")
            tts.speak(message)
            return
        }

        isProcessing = true
        defer {
            isProcessing = false
            print("[QuickVision][INFO] 종료 mode=\(mode.rawValue) success=\(lastResult != nil)")
        }

        errorMessage = nil
        lastResult = nil
        lastImage = nil
        lastMode = mode

        print(
            "[QuickVision][INFO] 시작 mode=\(mode.rawValue) provider=Google Gemini "
            + "model=\(model) hasDevice=\(streamViewModel.hasActiveDevice) "
            + "streamStatus=\(streamViewModel.streamingStatus)"
        )

        guard let apiKey = APIKeyManager.shared.getGoogleAPIKey(), !apiKey.isEmpty else {
            let message = "설정에서 Google Gemini API Key를 먼저 등록하세요"
            errorMessage = message
            record.status = .failed
            record.errorCode = "api_key_missing"
            record.errorMessage = message
            QuickVisionStorage.shared.upsertRecord(record)
            print("[QuickVision][ERROR] Google Gemini 인증 설정 없음")
            tts.speak(message)
            return
        }

        tts.speak("인식 중입니다")

        do {
            guard streamViewModel.hasActiveDevice else {
                throw QuickVisionError.noDevice
            }

            if streamViewModel.streamingStatus != .streaming {
                print("[QuickVision][INFO] 영상 스트림 시작 요청")
                await streamViewModel.handleStartStreaming()

                var streamWaitCount = 0
                while streamViewModel.streamingStatus != .streaming && streamWaitCount < 50 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    streamWaitCount += 1
                }

                print(
                    "[QuickVision][INFO] 스트림 대기 종료 elapsedMs=\(streamWaitCount * 100) "
                    + "status=\(streamViewModel.streamingStatus)"
                )
                guard streamViewModel.streamingStatus == .streaming else {
                    throw QuickVisionError.streamNotReady
                }
            }

            try await Task.sleep(nanoseconds: 500_000_000)
            streamViewModel.dismissPhotoPreview()
            streamViewModel.capturePhoto()
            print("[QuickVision][INFO] 사진 촬영 요청 완료")

            var photoWaitCount = 0
            while streamViewModel.capturedPhoto == nil && photoWaitCount < 30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                photoWaitCount += 1
            }

            let photo: UIImage
            if let capturedPhoto = streamViewModel.capturedPhoto {
                photo = capturedPhoto
                record.captureSource = "photo"
                print(
                    "[QuickVision][INFO] 촬영 사진 사용 size=\(capturedPhoto.size.width)x\(capturedPhoto.size.height) "
                    + "elapsedMs=\(photoWaitCount * 100)"
                )
            } else if let videoFrame = streamViewModel.currentVideoFrame {
                photo = videoFrame
                record.captureSource = "videoFrame"
                print(
                    "[QuickVision][WARN] 촬영 사진이 없어 최신 영상 프레임 사용 "
                    + "size=\(videoFrame.size.width)x\(videoFrame.size.height)"
                )
            } else {
                throw QuickVisionError.frameTimeout
            }

            record.setThumbnail(photo)
            QuickVisionStorage.shared.upsertRecord(record)
            lastImage = photo

            tts.prepareAudioSession()
            await streamViewModel.stopSession()
            print("[QuickVision][INFO] 영상 스트림 중지 완료. Gemini 이미지 분석 요청 시작")

            let service = QuickVisionService(apiKey: apiKey, model: model)
            let result = try await service.analyzeImage(photo, customPrompt: prompt)
            lastResult = result
            record.status = .succeeded
            record.result = result
            QuickVisionStorage.shared.upsertRecord(record)
            print("[QuickVision][INFO] 인식 성공 resultLength=\(result.count)")
            tts.speak(result)
        } catch let error as QuickVisionError {
            let message = "인식에 실패했습니다. 다시 시도하세요"
            errorMessage = message
            record.status = .failed
            record.errorCode = failureCode(for: error)
            record.errorMessage = message
            QuickVisionStorage.shared.upsertRecord(record)
            let nsError = error as NSError
            print(
                "[QuickVision][ERROR] 단계 실패 type=QuickVisionError domain=\(nsError.domain) "
                + "code=\(nsError.code) description=\(nsError.localizedDescription) "
                + "mode=\(mode.rawValue) model=\(model)"
            )
            tts.speak(message)
            await streamViewModel.stopSession()
        } catch {
            let nsError = error as NSError
            let message = "인식에 실패했습니다. 다시 시도하세요"
            errorMessage = message
            record.status = .failed
            record.errorCode = "unexpected_error"
            record.errorMessage = message
            QuickVisionStorage.shared.upsertRecord(record)
            print(
                "[QuickVision][ERROR] 예상하지 못한 실패 domain=\(nsError.domain) "
                + "code=\(nsError.code) description=\(nsError.localizedDescription) "
                + "mode=\(mode.rawValue) model=\(model)"
            )
            tts.speak(message)
            await streamViewModel.stopSession()
        }
    }

    private func failureCode(for error: QuickVisionError) -> String {
        switch error {
        case .noDevice: return "no_device"
        case .streamNotReady: return "stream_not_ready"
        case .frameTimeout: return "frame_timeout"
        case .apiKeyMissing: return "api_key_missing"
        case .invalidImage: return "invalid_image"
        case .emptyResponse: return "empty_response"
        case .invalidResponse: return "invalid_response"
        case .apiError: return "api_error"
        case .network: return "network_error"
        case .blocked: return "blocked"
        }
    }

    func performQuickVision(customPrompt: String? = nil) async {
        await performQuickVisionWithMode(
            QuickVisionModeManager.staticCurrentMode,
            customPrompt: customPrompt
        )
    }

    func performQuickVisionFromIntent(customPrompt: String? = nil) async {
        await performQuickVision(customPrompt: customPrompt)
    }

    func stopStream() async {
        await streamViewModel?.stopSession()
    }

    func triggerQuickVision(customPrompt: String? = nil) {
        Task { @MainActor in
            await performQuickVision(customPrompt: customPrompt)
        }
    }

    func triggerQuickVisionWithMode(_ mode: QuickVisionMode) {
        Task { @MainActor in
            await performQuickVisionWithMode(mode)
        }
    }
}

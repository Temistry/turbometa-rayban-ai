import AppIntents
import UIKit
import SwiftUI

@available(iOS 16.0, *)
struct QuickVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "이거 뭐야"
    static var description = IntentDescription("Ray-Ban Meta 안경으로 사진을 찍고 눈앞의 장면을 설명합니다")
    static var openAppWhenRun: Bool = false

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
    static var description = IntentDescription("음식이나 음료의 건강 정보를 분석합니다")
    static var openAppWhenRun: Bool = false

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
    static var description = IntentDescription("눈앞의 환경과 장애물, 사람과 사물의 위치를 설명합니다")
    static var openAppWhenRun: Bool = false

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
    static var description = IntentDescription("눈앞의 글자를 인식하고 읽어줍니다")
    static var openAppWhenRun: Bool = false

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
    static var description = IntentDescription("눈앞의 외국어 글자를 인식하고 번역합니다")
    static var openAppWhenRun: Bool = false

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
    static var description = IntentDescription("눈앞의 사물을 인식하고 관련 정보를 설명합니다")
    static var openAppWhenRun: Bool = false

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
        return .result(dialog: "인식 완료: \(result)")
    } else if let error = manager.errorMessage {
        return .result(dialog: "인식 실패: \(error)")
    } else {
        return .result(dialog: "인식이 완료되었습니다")
    }
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
                "\(.applicationName) 사진 인식"
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

        AppShortcut(
            intent: LiveAIIntent(),
            phrases: [
                "\(.applicationName) 실시간 대화",
                "\(.applicationName) 대화 시작",
                "\(.applicationName) 실시간 대화 시작"
            ],
            shortTitle: "실시간 대화",
            systemImageName: "brain.head.profile"
        )

        AppShortcut(
            intent: StopLiveAIIntent(),
            phrases: [
                "\(.applicationName) 실시간 대화 중지",
                "\(.applicationName) 대화 그만",
                "\(.applicationName) 대화 종료"
            ],
            shortTitle: "실시간 대화 중지",
            systemImageName: "stop.circle.fill"
        )
    }
}

extension Notification.Name {
    static let quickVisionTriggered = Notification.Name("quickVisionTriggered")
}

@MainActor
class QuickVisionManager: ObservableObject {
    static let shared = QuickVisionManager()

    @Published var isProcessing = false
    @Published var lastResult: String?
    @Published var errorMessage: String?
    @Published var lastImage: UIImage?
    @Published var lastMode: QuickVisionMode = .standard

    private(set) var streamViewModel: StreamSessionViewModel?
    private let tts = TTSService.shared

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleQuickVisionTrigger(_:)), name: .quickVisionTriggered, object: nil)
    }

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) { self.streamViewModel = viewModel }

    @objc private func handleQuickVisionTrigger(_ notification: Notification) {
        let customPrompt = notification.userInfo?["customPrompt"] as? String
        let modeString = notification.userInfo?["mode"] as? String
        let mode = modeString.flatMap { QuickVisionMode(rawValue: $0) } ?? .standard
        Task { @MainActor in await performQuickVisionWithMode(mode, customPrompt: customPrompt) }
    }

    func performQuickVisionWithMode(_ mode: QuickVisionMode, customPrompt: String? = nil) async {
        guard !isProcessing else { return }
        guard let streamViewModel = streamViewModel else {
            tts.speak("이미지 인식 기능이 준비되지 않았습니다. 먼저 앱을 열어주세요")
            return
        }

        isProcessing = true
        errorMessage = nil
        lastResult = nil
        lastImage = nil
        lastMode = mode

        guard let apiKey = APIKeyManager.shared.getAPIKey(), !apiKey.isEmpty else {
            errorMessage = "설정에서 API 키를 먼저 등록해주세요"
            tts.speak("설정에서 API 키를 먼저 등록해주세요")
            isProcessing = false
            return
        }

        tts.speak("인식 중입니다", apiKey: apiKey)
        let prompt = customPrompt ?? QuickVisionModeManager.shared.getPrompt(for: mode)

        do {
            if !streamViewModel.hasActiveDevice { throw QuickVisionError.noDevice }

            if streamViewModel.streamingStatus != .streaming {
                await streamViewModel.handleStartStreaming()
                var streamWait = 0
                while streamViewModel.streamingStatus != .streaming && streamWait < 50 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    streamWait += 1
                }
                if streamViewModel.streamingStatus != .streaming { throw QuickVisionError.streamNotReady }
            }

            try await Task.sleep(nanoseconds: 500_000_000)
            streamViewModel.dismissPhotoPreview()
            streamViewModel.capturePhoto()

            var photoWait = 0
            while streamViewModel.capturedPhoto == nil && photoWait < 30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                photoWait += 1
            }

            let photo: UIImage
            if let capturedPhoto = streamViewModel.capturedPhoto {
                photo = capturedPhoto
            } else if let videoFrame = streamViewModel.currentVideoFrame {
                photo = videoFrame
            } else {
                throw QuickVisionError.frameTimeout
            }

            lastImage = photo
            tts.prepareAudioSession()
            await streamViewModel.stopSession()

            let service = QuickVisionService(apiKey: apiKey)
            let result = try await service.analyzeImage(photo, customPrompt: prompt)
            lastResult = result
            saveToHistory(mode: mode, prompt: prompt, result: result, image: photo)
            tts.speak(result, apiKey: apiKey)
        } catch let error as QuickVisionError {
            errorMessage = error.localizedDescription
            tts.speak(error.localizedDescription, apiKey: apiKey)
            await streamViewModel.stopSession()
        } catch {
            errorMessage = error.localizedDescription
            tts.speak("인식에 실패했습니다. \(error.localizedDescription)", apiKey: apiKey)
            await streamViewModel.stopSession()
        }

        isProcessing = false
    }

    func performQuickVision(customPrompt: String? = nil) async {
        await performQuickVisionWithMode(QuickVisionModeManager.staticCurrentMode, customPrompt: customPrompt)
    }

    func performQuickVisionFromIntent(customPrompt: String? = nil) async { await performQuickVision(customPrompt: customPrompt) }

    private func saveToHistory(mode: QuickVisionMode, prompt: String, result: String, image: UIImage) {
        let record = QuickVisionRecord(mode: mode, prompt: prompt, result: result, thumbnail: image)
        QuickVisionStorage.shared.saveRecord(record)
    }

    func stopStream() async { await streamViewModel?.stopSession() }

    func triggerQuickVision(customPrompt: String? = nil) {
        Task { @MainActor in await performQuickVision(customPrompt: customPrompt) }
    }

    func triggerQuickVisionWithMode(_ mode: QuickVisionMode) {
        Task { @MainActor in await performQuickVisionWithMode(mode) }
    }
}

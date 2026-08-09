/*
 * Google Gemini 중심 AI 설정 관리자
 *
 * 일반 사용자 실행 경로는 Google Gemini로 고정한다.
 * Alibaba/OpenRouter 타입과 Keychain 항목은 기존 설치 데이터와 개발자 호환성을 위해
 * 당분간 남기지만 일반 UI와 기본 실행 경로에서는 사용하지 않는다.
 */

import Foundation
import SwiftUI

// MARK: - Gemini models

enum GeminiModelCatalog {
    static let quickVision = "gemini-3.6-flash"
    static let live = "gemini-3.1-flash-live-preview"
    static let liveTranslate = live
}

// MARK: - Legacy Alibaba endpoint compatibility

enum AlibabaEndpoint: String, CaseIterable, Codable {
    case beijing = "beijing"
    case singapore = "singapore"

    var displayName: String {
        switch self {
        case .beijing: return "베이징(중국 본토)"
        case .singapore: return "싱가포르(국제)"
        }
    }

    var baseURL: String {
        switch self {
        case .beijing: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .singapore: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        }
    }

    var websocketURL: String {
        switch self {
        case .beijing: return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        case .singapore: return "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime"
        }
    }
}

// MARK: - Vision provider

enum APIProvider: String, CaseIterable, Codable {
    case google = "google"
    case alibaba = "alibaba"
    case openrouter = "openrouter"

    var displayName: String {
        switch self {
        case .google: return "Google Gemini"
        case .alibaba: return "Alibaba Cloud DashScope"
        case .openrouter: return "OpenRouter"
        }
    }

    func baseURL(endpoint: AlibabaEndpoint = .beijing) -> String {
        switch self {
        case .google:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .alibaba:
            return endpoint.baseURL
        case .openrouter:
            return "https://openrouter.ai/api/v1"
        }
    }

    var baseURL: String { baseURL(endpoint: .beijing) }

    var defaultModel: String {
        switch self {
        case .google: return GeminiModelCatalog.quickVision
        case .alibaba: return "qwen3-vl-plus"
        case .openrouter: return "google/gemini-3.6-flash"
        }
    }

    var apiKeyHelpURL: String {
        switch self {
        case .google: return "https://aistudio.google.com/apikey"
        case .alibaba: return "https://help.aliyun.com/zh/model-studio/get-api-key"
        case .openrouter: return "https://openrouter.ai/keys"
        }
    }

    var supportsVision: Bool { true }
}

// MARK: - Live AI provider

enum LiveAIProvider: String, CaseIterable, Codable {
    case google = "google"
    case alibaba = "alibaba"

    var displayName: String {
        switch self {
        case .google: return "Google Gemini Live"
        case .alibaba: return "Alibaba Qwen Omni"
        }
    }

    var defaultModel: String {
        switch self {
        case .google: return GeminiModelCatalog.live
        case .alibaba: return "qwen3-omni-flash-realtime"
        }
    }

    var apiKeyHelpURL: String {
        switch self {
        case .google: return "https://aistudio.google.com/apikey"
        case .alibaba: return "https://help.aliyun.com/zh/model-studio/get-api-key"
        }
    }

    func websocketURL(endpoint: AlibabaEndpoint = .beijing) -> String {
        switch self {
        case .google:
            return "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        case .alibaba:
            return endpoint.websocketURL
        }
    }
}

// MARK: - Legacy OpenRouter model compatibility

struct OpenRouterModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let contextLength: Int?
    let pricing: Pricing?
    let architecture: Architecture?

    var displayName: String { name.isEmpty ? id : name }

    var isVisionCapable: Bool {
        if let architecture {
            return architecture.modality?.contains("image") == true
                || architecture.modality?.contains("multimodal") == true
        }

        let patterns = ["vision", "vl", "gpt-4o", "claude-3", "gemini"]
        return patterns.contains { id.lowercased().contains($0) }
    }

    var priceDisplay: String {
        guard let pricing else { return "" }
        let promptPrice = (Double(pricing.prompt) ?? 0) * 1_000_000
        let completionPrice = (Double(pricing.completion) ?? 0) * 1_000_000
        return String(format: "입력 $%.2f / 출력 $%.2f · 100만 토큰", promptPrice, completionPrice)
    }

    struct Pricing: Codable, Hashable {
        let prompt: String
        let completion: String
    }

    struct Architecture: Codable, Hashable {
        let modality: String?
        let tokenizer: String?
        let instructType: String?

        enum CodingKeys: String, CodingKey {
            case modality
            case tokenizer
            case instructType = "instruct_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case contextLength = "context_length"
        case pricing
        case architecture
    }
}

struct OpenRouterModelsResponse: Codable {
    let data: [OpenRouterModel]
}

// MARK: - Manager

@MainActor
final class APIProviderManager: ObservableObject {
    static let shared = APIProviderManager()

    private let providerKey = "api_provider"
    private let selectedModelKey = "selected_vision_model"
    private let alibabaEndpointKey = "alibaba_endpoint"
    private let liveAIProviderKey = "liveai_provider"
    private let liveAIModelKey = "liveai_model"

    @Published var currentProvider: APIProvider {
        didSet {
            UserDefaults.standard.set(currentProvider.rawValue, forKey: providerKey)
            if oldValue != currentProvider {
                selectedModel = currentProvider.defaultModel
            }
        }
    }

    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: selectedModelKey)
        }
    }

    @Published var alibabaEndpoint: AlibabaEndpoint {
        didSet {
            UserDefaults.standard.set(alibabaEndpoint.rawValue, forKey: alibabaEndpointKey)
        }
    }

    @Published var liveAIProvider: LiveAIProvider {
        didSet {
            UserDefaults.standard.set(liveAIProvider.rawValue, forKey: liveAIProviderKey)
            if oldValue != liveAIProvider {
                liveAIModel = liveAIProvider.defaultModel
            }
        }
    }

    @Published var liveAIModel: String {
        didSet {
            UserDefaults.standard.set(liveAIModel, forKey: liveAIModelKey)
        }
    }

    @Published var openRouterModels: [OpenRouterModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?

    private init() {
        let savedEndpoint = UserDefaults.standard.string(forKey: alibabaEndpointKey)
            ?? AlibabaEndpoint.beijing.rawValue
        alibabaEndpoint = AlibabaEndpoint(rawValue: savedEndpoint) ?? .beijing

        currentProvider = .google
        selectedModel = GeminiModelCatalog.quickVision
        liveAIProvider = .google
        liveAIModel = GeminiModelCatalog.live

        UserDefaults.standard.set(APIProvider.google.rawValue, forKey: providerKey)
        UserDefaults.standard.set(GeminiModelCatalog.quickVision, forKey: selectedModelKey)
        UserDefaults.standard.set(LiveAIProvider.google.rawValue, forKey: liveAIProviderKey)
        UserDefaults.standard.set(GeminiModelCatalog.live, forKey: liveAIModelKey)
    }

    var liveAIWebSocketURL: String {
        LiveAIProvider.google.websocketURL()
    }

    var liveAIAPIKey: String {
        APIKeyManager.shared.getGoogleAPIKey() ?? ""
    }

    var hasLiveAIAPIKey: Bool { !liveAIAPIKey.isEmpty }

    var currentBaseURL: String {
        APIProvider.google.baseURL()
    }

    var currentAPIKey: String {
        APIKeyManager.shared.getGoogleAPIKey() ?? ""
    }

    var currentModel: String { GeminiModelCatalog.quickVision }

    var hasAPIKey: Bool {
        APIKeyManager.shared.hasGoogleAPIKey()
    }

    // 개발자 호환 화면에서만 사용한다. 일반 사용자 UI에서는 호출하지 않는다.
    func fetchOpenRouterModels() async {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: .openrouter), !apiKey.isEmpty else {
            modelsError = "OpenRouter API Key가 설정되어 있지 않습니다"
            print("[APIProvider][WARN] 개발자용 OpenRouter 모델 목록 요청 생략 reason=credentialUnavailable")
            return
        }

        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }

        do {
            guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
                throw NSError(
                    domain: "OpenRouter",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "모델 목록 URL이 올바르지 않습니다"]
                )
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("TurboMeta", forHTTPHeaderField: "X-Title")
            request.timeoutInterval = 30

            let startedAt = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "OpenRouter",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP 응답을 받지 못했습니다"]
                )
            }

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            print("[APIProvider][HTTP] 개발자용 모델 목록 status=\(httpResponse.statusCode) elapsedMs=\(elapsedMs) bytes=\(data.count)")

            guard httpResponse.statusCode == 200 else {
                throw NSError(
                    domain: "OpenRouter",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "모델 목록을 가져오지 못했습니다"]
                )
            }

            let responseBody = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
            openRouterModels = responseBody.data.sorted { first, second in
                if first.isVisionCapable != second.isVisionCapable {
                    return first.isVisionCapable
                }
                return first.displayName < second.displayName
            }
        } catch {
            let nsError = error as NSError
            modelsError = error.localizedDescription
            print("[APIProvider][ERROR] 개발자용 모델 목록 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    func searchModels(_ query: String) -> [OpenRouterModel] {
        guard !query.isEmpty else { return openRouterModels }
        let lowercasedQuery = query.lowercased()
        return openRouterModels.filter { model in
            model.id.lowercased().contains(lowercasedQuery)
                || model.displayName.lowercased().contains(lowercasedQuery)
                || (model.description?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }

    func visionCapableModels() -> [OpenRouterModel] {
        openRouterModels.filter(\.isVisionCapable)
    }
}

// MARK: - Static access for services

extension APIProviderManager {
    nonisolated static var staticCurrentProvider: APIProvider { .google }

    nonisolated static var staticAlibabaEndpoint: AlibabaEndpoint {
        let value = UserDefaults.standard.string(forKey: "alibaba_endpoint")
            ?? AlibabaEndpoint.beijing.rawValue
        return AlibabaEndpoint(rawValue: value) ?? .beijing
    }

    nonisolated static var staticLiveAIProvider: LiveAIProvider { .google }

    nonisolated static var staticLiveAIAPIKey: String {
        APIKeyManager.shared.getGoogleAPIKey() ?? ""
    }

    nonisolated static var staticCurrentModel: String {
        GeminiModelCatalog.quickVision
    }

    nonisolated static var staticBaseURL: String {
        APIProvider.google.baseURL()
    }

    nonisolated static var staticAPIKey: String {
        APIKeyManager.shared.getGoogleAPIKey() ?? ""
    }

    nonisolated static var staticLiveAIWebsocketURL: String {
        LiveAIProvider.google.websocketURL()
    }
}

/*
 * TurboMeta 설정 화면
 * 앱과 AI의 표시/출력 언어는 한국어로 고정한다.
 */

import MWDATCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var languageManager = LanguageManager.shared
    @ObservedObject var providerManager = APIProviderManager.shared
    @ObservedObject var quickVisionModeManager = QuickVisionModeManager.shared
    @ObservedObject var openClawService = OpenClawNodeService.shared
    #if DEBUG || INTERNAL_BUILD
    @ObservedObject var developerConsole = DeveloperConsole.shared
    #endif

    let apiKey: String

    @State private var showAPIKeySettings = false
    @State private var showProviderSettings = false
    @State private var showModelSettings = false
    @State private var showQualitySettings = false
    @State private var showGoogleAPIKeySettings = false
    @State private var showQuickVisionSettings = false
    @State private var showOpenClawSettings = false

    @State private var selectedQuality = UserDefaults.standard.string(forKey: "video_quality") ?? "medium"
    @State private var hasAPIKey = false
    @State private var hasGoogleAPIKey = false

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        self.apiKey = apiKey
    }

    private func refreshAPIKeyStatus() {
        hasAPIKey = providerManager.hasAPIKey
        hasGoogleAPIKey = APIKeyManager.shared.hasGoogleAPIKey()
    }

    var body: some View {
        NavigationView {
            List {
                deviceSection
                koreanLanguageSection
                visionAISection
                integrationSection
                #if DEBUG || INTERNAL_BUILD
                developerSection
                #endif
                aboutSection
            }
            .navigationTitle("settings.title".localized)
            .sheet(isPresented: $showAPIKeySettings) {
                if providerManager.currentProvider == .alibaba {
                    APIKeySettingsView(
                        provider: providerManager.currentProvider,
                        endpoint: providerManager.alibabaEndpoint
                    )
                } else {
                    APIKeySettingsView(provider: providerManager.currentProvider)
                }
            }
            .onChange(of: showAPIKeySettings) { isShowing in
                if !isShowing { refreshAPIKeyStatus() }
            }
            .sheet(isPresented: $showProviderSettings) {
                APIProviderSettingsView()
            }
            .onChange(of: showProviderSettings) { isShowing in
                if !isShowing { refreshAPIKeyStatus() }
            }
            .sheet(isPresented: $showModelSettings) {
                VisionModelSettingsView()
            }
            .sheet(isPresented: $showQualitySettings) {
                VideoQualitySettingsView(selectedQuality: $selectedQuality)
            }
            .sheet(isPresented: $showGoogleAPIKeySettings) {
                GoogleAPIKeySettingsView()
            }
            .onChange(of: showGoogleAPIKeySettings) { isShowing in
                if !isShowing { refreshAPIKeyStatus() }
            }
            .sheet(isPresented: $showQuickVisionSettings) {
                QuickVisionSettingsView()
            }
            .sheet(isPresented: $showOpenClawSettings) {
                OpenClawSettingsView()
            }
            .onAppear {
                // 한국어 전용 빌드의 명시적 기본값이다.
                UserDefaults.standard.set("ko-KR", forKey: "output_language")
                refreshAPIKeyStatus()
            }
        }
    }

    private var deviceSection: some View {
        Section {
            HStack {
                Image(systemName: "eye.circle.fill")
                    .foregroundColor(AppColors.primary)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ray-Ban Meta")
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                    Text(streamViewModel.hasActiveDevice
                         ? "settings.device.connected".localized
                         : "settings.device.notconnected".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(streamViewModel.hasActiveDevice ? .green : AppColors.textSecondary)
                }

                Spacer()
                Circle()
                    .fill(streamViewModel.hasActiveDevice ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
            }
            .padding(.vertical, AppSpacing.sm)

            InfoRow(
                title: "settings.device.status".localized,
                value: streamViewModel.hasActiveDevice
                    ? "settings.device.online".localized
                    : "settings.device.offline".localized
            )

            InfoRow(
                title: "settings.device.stream".localized,
                value: streamViewModel.isStreaming
                    ? "settings.device.stream.active".localized
                    : "settings.device.stream.inactive".localized
            )
        } header: {
            Text("settings.device".localized)
        }
    }

    private var koreanLanguageSection: some View {
        Section {
            InfoRow(title: "settings.applanguage".localized, value: "한국어")
            InfoRow(title: "settings.language".localized, value: "한국어")
        } header: {
            Text("언어")
        } footer: {
            Text("이 개발 빌드는 화면, AI 응답, Siri 문구와 음성 출력을 한국어로 고정합니다.")
        }
    }

    private var visionAISection: some View {
        Section {
            SettingsNavigationRow(
                icon: "server.rack",
                iconColor: AppColors.accent,
                title: "settings.provider".localized,
                value: providerManager.currentProvider.displayName
            ) {
                showProviderSettings = true
            }

            SettingsNavigationRow(
                icon: "cpu",
                iconColor: AppColors.accent,
                title: "settings.model".localized,
                value: providerManager.selectedModel
            ) {
                showModelSettings = true
            }

            SettingsNavigationRow(
                icon: "key.fill",
                iconColor: AppColors.wordLearn,
                title: "settings.apikey".localized,
                value: hasAPIKey
                    ? "settings.apikey.configured".localized
                    : "settings.apikey.notconfigured".localized,
                valueColor: hasAPIKey ? .green : .red
            ) {
                showAPIKeySettings = true
            }

            SettingsNavigationRow(
                icon: "video.fill",
                iconColor: AppColors.liveStream,
                title: "settings.quality".localized,
                value: qualityDisplayName(selectedQuality)
            ) {
                showQualitySettings = true
            }

            SettingsNavigationRow(
                icon: "eye.circle.fill",
                iconColor: AppColors.quickVision,
                title: "quickvision.settings".localized,
                value: quickVisionModeManager.currentMode.displayName
            ) {
                showQuickVisionSettings = true
            }
        } header: {
            Text("settings.ai".localized)
        }
    }

    private var integrationSection: some View {
        Section {
            SettingsNavigationRow(
                icon: "link.circle.fill",
                iconColor: .purple,
                title: "OpenClaw",
                value: openClawStatusText,
                valueColor: openClawStatusColor
            ) {
                showOpenClawSettings = true
            }
        } header: {
            Text("settings.integrations".localized)
        }
    }

    #if DEBUG || INTERNAL_BUILD
    private var developerSection: some View {
        Section {
            Button {
                developerConsole.present()
            } label: {
                HStack {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.orange)
                    Text("개발자 로그")
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    if developerConsole.unreadErrorCount > 0 {
                        Text("오류 \(developerConsole.unreadErrorCount)개")
                            .font(AppTypography.caption)
                            .foregroundColor(.red)
                    } else {
                        Text("\(developerConsole.entries.count)줄")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textTertiary)
                }
            }

            InfoRow(title: "로그 보관", value: "기기 메모리만 사용")
            InfoRow(title: "자격 증명", value: "자동 마스킹")
        } header: {
            Text("개발자 진단")
        }
    }
    #endif

    private var aboutSection: some View {
        Section {
            InfoRow(title: "settings.version".localized, value: "2.0.0")
            InfoRow(title: "settings.sdkversion".localized, value: "0.5.0")
        } header: {
            Text("settings.about".localized)
        }
    }

    private var openClawStatusColor: Color {
        switch openClawService.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .waitingForPairing: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var openClawStatusText: String {
        switch openClawService.connectionState {
        case .connected: return "openclaw.status.connected".localized
        case .connecting: return "openclaw.status.connecting".localized
        case .waitingForPairing: return "openclaw.status.pairing".localized
        case .error: return "오류"
        case .disconnected: return "openclaw.status.disconnected".localized
        }
    }

    private func qualityDisplayName(_ code: String) -> String {
        switch code {
        case "low": return "settings.quality.low".localized
        case "high": return "settings.quality.high".localized
        default: return "settings.quality.medium".localized
        }
    }
}

// MARK: - Shared rows

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(AppTypography.body)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            Text(value)
                .font(AppTypography.body)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var value: String? = nil
    var valueColor: Color = AppColors.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                Text(title)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                if let value {
                    Text(value)
                        .font(AppTypography.caption)
                        .foregroundColor(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }
}

// MARK: - API provider settings

struct APIProviderSettingsView: View {
    @ObservedObject var providerManager = APIProviderManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(APIProvider.allCases, id: \.self) { provider in
                        Button {
                            providerManager.currentProvider = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.displayName)
                                        .foregroundColor(.primary)
                                    Text(provider == .alibaba
                                         ? "settings.provider.alibaba.desc".localized
                                         : "settings.provider.openrouter.desc".localized)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if providerManager.currentProvider == provider {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.provider.select".localized)
                } footer: {
                    Text("settings.provider.description".localized)
                }

                if providerManager.currentProvider == .alibaba {
                    Section {
                        ForEach(AlibabaEndpoint.allCases, id: \.self) { endpoint in
                            Button {
                                providerManager.alibabaEndpoint = endpoint
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(endpoint.displayName)
                                            .foregroundColor(.primary)
                                        Text(endpoint == .beijing
                                             ? "settings.endpoint.beijing.desc".localized
                                             : "settings.endpoint.singapore.desc".localized)
                                            .font(AppTypography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                    }
                                    Spacer()
                                    if providerManager.alibabaEndpoint == endpoint {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("settings.endpoint".localized)
                    } footer: {
                        Text("settings.endpoint.description".localized)
                    }
                }

                Section {
                    HStack {
                        Text("settings.apikey.status".localized)
                        Spacer()
                        Label(
                            providerManager.hasAPIKey
                                ? "settings.apikey.configured".localized
                                : "settings.apikey.notconfigured".localized,
                            systemImage: providerManager.hasAPIKey
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill"
                        )
                        .foregroundColor(providerManager.hasAPIKey ? .green : .red)
                    }

                    Link(destination: URL(string: providerManager.currentProvider.apiKeyHelpURL)!) {
                        HStack {
                            Text("settings.provider.getapikey".localized)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                } header: {
                    Text("API Key")
                }
            }
            .navigationTitle("settings.provider".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
    }
}

// MARK: - API Key settings

struct APIKeySettingsView: View {
    let provider: APIProvider
    var endpoint: AlibabaEndpoint? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var showSaveSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var displayTitle: String {
        if provider == .alibaba, let endpoint {
            return "\(provider.displayName) · \(endpoint.displayName)"
        }
        return provider.displayName
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("settings.apikey.placeholder".localized, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(displayTitle)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider == .alibaba
                             ? "settings.apikey.alibaba.help".localized
                             : "settings.apikey.openrouter.help".localized)
                        Link("settings.apikey.get".localized, destination: URL(string: provider.apiKeyHelpURL)!)
                            .font(.caption)
                    }
                }

                Section {
                    Button("save".localized) { saveAPIKey() }
                        .frame(maxWidth: .infinity)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if APIKeyManager.shared.hasAPIKey(for: provider, endpoint: endpoint) {
                        Button("settings.apikey.delete".localized, role: .destructive) {
                            deleteAPIKey()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                Section {
                    Text("API Key는 현재 iPhone에서만 사용할 수 있는 Keychain에 저장되며 로그에는 출력되지 않습니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("보안")
                }
            }
            .navigationTitle("settings.apikey.manage".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
            .alert("settings.apikey.saved".localized, isPresented: $showSaveSuccess) {
                Button("ok".localized) { dismiss() }
            } message: {
                Text("settings.apikey.saved.message".localized)
            }
            .alert("error".localized, isPresented: $showError) {
                Button("ok".localized) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                apiKey = APIKeyManager.shared.getAPIKey(for: provider, endpoint: endpoint) ?? ""
            }
        }
    }

    private func saveAPIKey() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "settings.apikey.empty".localized
            showError = true
            return
        }

        if APIKeyManager.shared.saveAPIKey(apiKey, for: provider, endpoint: endpoint) {
            showSaveSuccess = true
        } else {
            errorMessage = "settings.apikey.savefailed".localized
            showError = true
        }
    }

    private func deleteAPIKey() {
        if APIKeyManager.shared.deleteAPIKey(for: provider, endpoint: endpoint) {
            apiKey = ""
            dismiss()
        } else {
            errorMessage = "settings.apikey.deletefailed".localized
            showError = true
        }
    }
}

// MARK: - Vision model settings

struct VisionModelSettingsView: View {
    @ObservedObject var providerManager = APIProviderManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showVisionOnly = true

    var body: some View {
        NavigationView {
            Group {
                if providerManager.currentProvider == .alibaba {
                    alibabaModelList
                } else {
                    openRouterModelList
                }
            }
            .navigationTitle("settings.model".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
    }

    private var alibabaModelList: some View {
        let models = [
            ("qwen3-vl-plus", "Qwen3 VL Plus", "settings.model.qwen3vlplus.desc".localized),
            ("qwen3-vl-max", "Qwen3 VL Max", "settings.model.qwen3vlmax.desc".localized)
        ]

        return List {
            Section {
                ForEach(models, id: \.0) { model in
                    Button {
                        providerManager.selectedModel = model.0
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.1).foregroundColor(.primary)
                                Text(model.2)
                                    .font(AppTypography.caption)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            Spacer()
                            if providerManager.selectedModel == model.0 {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("settings.model.alibaba".localized)
            } footer: {
                Text("\("settings.model.current".localized): \(providerManager.selectedModel)")
            }
        }
    }

    private var openRouterModelList: some View {
        VStack {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("settings.model.search".localized, text: $searchText)
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            Toggle("settings.model.visiononly".localized, isOn: $showVisionOnly)
                .padding(.horizontal)
                .padding(.vertical, 4)

            if providerManager.isLoadingModels {
                Spacer()
                ProgressView("settings.model.loading".localized)
                Spacer()
            } else if let error = providerManager.modelsError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("settings.model.retry".localized) {
                        Task { await providerManager.fetchOpenRouterModels() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                Spacer()
            } else {
                List {
                    let models = filteredModels
                    if models.isEmpty {
                        Text("settings.model.notfound".localized)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(models) { model in
                            Button {
                                providerManager.selectedModel = model.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(model.displayName)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if model.isVisionCapable {
                                                Image(systemName: "eye.fill")
                                                    .font(.caption)
                                                    .foregroundColor(.purple)
                                            }
                                        }
                                        Text(model.id)
                                            .font(AppTypography.caption)
                                            .foregroundColor(AppColors.textSecondary)
                                            .lineLimit(1)
                                        if !model.priceDisplay.isEmpty {
                                            Text(model.priceDisplay)
                                                .font(.caption2)
                                                .foregroundColor(.green)
                                        }
                                    }
                                    Spacer()
                                    if providerManager.selectedModel == model.id {
                                        Image(systemName: "checkmark").foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            if providerManager.openRouterModels.isEmpty {
                await providerManager.fetchOpenRouterModels()
            }
        }
    }

    private var filteredModels: [OpenRouterModel] {
        var models = showVisionOnly
            ? providerManager.openRouterModels.filter { $0.isVisionCapable }
            : providerManager.openRouterModels

        if !searchText.isEmpty {
            models = providerManager.searchModels(searchText)
            if showVisionOnly {
                models = models.filter { $0.isVisionCapable }
            }
        }
        return models
    }
}

// MARK: - Korean-only language screens

struct LanguageSettingsView: View {
    @Binding var selectedLanguage: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("한국어")
                        Spacer()
                        Image(systemName: "checkmark").foregroundColor(.blue)
                    }
                } footer: {
                    Text("AI의 텍스트와 음성 출력은 한국어로 고정됩니다.")
                }
            }
            .navigationTitle("출력 언어")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") {
                        selectedLanguage = "ko-KR"
                        dismiss()
                    }
                }
            }
            .onAppear { selectedLanguage = "ko-KR" }
        }
    }
}

struct AppLanguageSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                HStack {
                    Text("한국어")
                    Spacer()
                    Image(systemName: "checkmark").foregroundColor(.blue)
                }
            }
            .navigationTitle("앱 언어")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Video quality

struct VideoQualitySettingsView: View {
    @Binding var selectedQuality: String
    @Environment(\.dismiss) private var dismiss

    private var qualities: [(String, String, String)] {
        [
            ("low", "settings.quality.low".localized, "settings.quality.low.desc".localized),
            ("medium", "settings.quality.medium".localized, "settings.quality.medium.desc".localized),
            ("high", "settings.quality.high".localized, "settings.quality.high.desc".localized)
        ]
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(qualities, id: \.0) { quality in
                        Button {
                            selectedQuality = quality.0
                            UserDefaults.standard.set(quality.0, forKey: "video_quality")
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(quality.1).foregroundColor(.primary)
                                    Text(quality.2)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if selectedQuality == quality.0 {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.quality.select".localized)
                } footer: {
                    Text("settings.quality.description".localized)
                }
            }
            .navigationTitle("settings.quality".localized)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Live AI provider

struct LiveAIProviderSettingsView: View {
    @ObservedObject var providerManager = APIProviderManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(LiveAIProvider.allCases, id: \.self) { provider in
                        Button {
                            providerManager.liveAIProvider = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(provider.displayName).foregroundColor(.primary)
                                    Text(provider == .alibaba
                                         ? "settings.liveai.alibaba.desc".localized
                                         : "settings.liveai.google.desc".localized)
                                        .font(AppTypography.caption)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if providerManager.liveAIProvider == provider {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.liveai.provider.select".localized)
                } footer: {
                    Text("settings.liveai.provider.description".localized)
                }

                Section {
                    HStack {
                        Text("settings.apikey.status".localized)
                        Spacer()
                        Label(
                            providerManager.hasLiveAIAPIKey
                                ? "settings.apikey.configured".localized
                                : "settings.apikey.notconfigured".localized,
                            systemImage: providerManager.hasLiveAIAPIKey
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill"
                        )
                        .foregroundColor(providerManager.hasLiveAIAPIKey ? .green : .red)
                    }

                    Link(destination: URL(string: providerManager.liveAIProvider.apiKeyHelpURL)!) {
                        HStack {
                            Text("settings.provider.getapikey".localized)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                } header: {
                    Text("API Key")
                }
            }
            .navigationTitle("settings.liveai.provider".localized)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Google API Key

struct GoogleAPIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var showSaveSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    SecureField("settings.apikey.placeholder".localized, text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Google Gemini API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.apikey.google.help".localized)
                        Link(
                            "settings.apikey.get".localized,
                            destination: URL(string: "https://aistudio.google.com/apikey")!
                        )
                        .font(.caption)
                    }
                }

                Section {
                    Button("save".localized) { saveAPIKey() }
                        .frame(maxWidth: .infinity)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if APIKeyManager.shared.hasGoogleAPIKey() {
                        Button("settings.apikey.delete".localized, role: .destructive) {
                            deleteAPIKey()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                Section {
                    Text("API Key는 현재 iPhone의 기기 전용 Keychain에 저장됩니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("보안")
                }
            }
            .navigationTitle("settings.apikey.manage".localized)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
            .alert("settings.apikey.saved".localized, isPresented: $showSaveSuccess) {
                Button("ok".localized) { dismiss() }
            } message: {
                Text("settings.apikey.saved.message".localized)
            }
            .alert("error".localized, isPresented: $showError) {
                Button("ok".localized) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                apiKey = APIKeyManager.shared.getGoogleAPIKey() ?? ""
            }
        }
    }

    private func saveAPIKey() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "settings.apikey.empty".localized
            showError = true
            return
        }

        if APIKeyManager.shared.saveGoogleAPIKey(apiKey) {
            showSaveSuccess = true
        } else {
            errorMessage = "settings.apikey.savefailed".localized
            showError = true
        }
    }

    private func deleteAPIKey() {
        if APIKeyManager.shared.deleteGoogleAPIKey() {
            apiKey = ""
            dismiss()
        } else {
            errorMessage = "settings.apikey.deletefailed".localized
            showError = true
        }
    }
}

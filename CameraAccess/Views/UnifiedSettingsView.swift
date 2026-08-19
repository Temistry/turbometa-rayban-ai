/*
 * Google Gemini 단일 공급자와 지식 로그 동기화를 위한 사용자 설정 화면
 */

import MWDATCore
import SwiftUI

struct UnifiedSettingsView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var quickVisionModeManager = QuickVisionModeManager.shared
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    #if DEBUG
    @ObservedObject private var developerConsole = DeveloperConsole.shared
    #endif
    @ObservedObject private var knowledgeLog = KnowledgeLogService.shared

    @State private var showGoogleAPIKeySettings = false
    @State private var showQualitySettings = false
    @State private var showQuickVisionSettings = false
    @State private var showOpenClawSettings = false
    @State private var showKnowledgeFolderPicker = false
    @State private var showKnowledgeError = false
    @State private var knowledgeErrorMessage = ""

    @State private var selectedQuality = UserDefaults.standard.string(forKey: "video_quality") ?? "medium"
    @State private var hasGoogleAPIKey = false

    var body: some View {
        NavigationView {
            List {
                deviceSection
                languageSection
                googleAISection
                knowledgeLogSection
                integrationSection
                #if DEBUG
                developerSection
                #endif
                aboutSection
            }
            .navigationTitle("settings.title".localized)
            .sheet(isPresented: $showGoogleAPIKeySettings) {
                GoogleAPIKeySettingsView()
            }
            .onChange(of: showGoogleAPIKeySettings) { isShowing in
                if !isShowing { refreshAPIKeyStatus() }
            }
            .sheet(isPresented: $showQualitySettings) {
                VideoQualitySettingsView(selectedQuality: $selectedQuality)
            }
            .sheet(isPresented: $showQuickVisionSettings) {
                QuickVisionSettingsView()
            }
            .sheet(isPresented: $showOpenClawSettings) {
                OpenClawSettingsView()
            }
            .sheet(isPresented: $showKnowledgeFolderPicker) {
                KnowledgeLogFolderPicker { url in
                    configureKnowledgeFolder(url)
                }
            }
            .alert("지식 로그 동기화 오류", isPresented: $showKnowledgeError) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(knowledgeErrorMessage)
            }
            .onAppear {
                UserDefaults.standard.set("ko-KR", forKey: "output_language")
                refreshAPIKeyStatus()
            }
            .onChange(of: knowledgeLog.lastErrorMessage) { _, message in
                guard let message, !message.isEmpty else { return }
                knowledgeErrorMessage = message
                showKnowledgeError = true
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

            UnifiedInfoRow(
                title: "settings.device.status".localized,
                value: streamViewModel.hasActiveDevice
                    ? "settings.device.online".localized
                    : "settings.device.offline".localized
            )

            UnifiedInfoRow(
                title: "settings.device.stream".localized,
                value: streamViewModel.isStreaming
                    ? "settings.device.stream.active".localized
                    : "settings.device.stream.inactive".localized
            )
        } header: {
            Text("settings.device".localized)
        }
    }

    private var languageSection: some View {
        Section {
            UnifiedInfoRow(title: "settings.applanguage".localized, value: "한국어")
            UnifiedInfoRow(title: "settings.language".localized, value: "한국어")
        } header: {
            Text("언어")
        } footer: {
            Text("화면, Gemini 응답, Siri 문구와 퀵비전 음성 출력을 한국어로 사용합니다.")
        }
    }

    private var googleAISection: some View {
        Section {
            UnifiedSettingsRow(
                icon: "key.fill",
                iconColor: .orange,
                title: "Google Gemini API Key",
                value: hasGoogleAPIKey
                    ? "settings.apikey.configured".localized
                    : "settings.apikey.notconfigured".localized,
                valueColor: hasGoogleAPIKey ? .green : .red
            ) {
                showGoogleAPIKeySettings = true
            }

            UnifiedInfoRow(title: "퀵비전 모델", value: GeminiModelCatalog.quickVision)

            UnifiedSettingsRow(
                icon: "video.fill",
                iconColor: AppColors.liveStream,
                title: "settings.quality".localized,
                value: qualityDisplayName(selectedQuality)
            ) {
                showQualitySettings = true
            }

            UnifiedSettingsRow(
                icon: "eye.circle.fill",
                iconColor: AppColors.quickVision,
                title: "quickvision.settings".localized,
                value: quickVisionModeManager.currentMode.displayName
            ) {
                showQuickVisionSettings = true
            }
        } header: {
            Text("Google Gemini")
        } footer: {
            Text("퀵비전과 음식 분석은 같은 Google Gemini 인증 설정을 사용합니다. 퀵비전 낭독은 iOS 한국어 시스템 음성을 사용합니다.")
        }
    }

    private var knowledgeLogSection: some View {
        Section {
            UnifiedSettingsRow(
                icon: "folder.badge.plus",
                iconColor: .blue,
                title: "동기화 폴더",
                value: knowledgeLog.destinationStatusText,
                valueColor: knowledgeLog.isDestinationConfigured ? .green : .orange
            ) {
                showKnowledgeFolderPicker = true
            }

            UnifiedInfoRow(title: "저장 형식", value: "Markdown + JSONL")
            UnifiedInfoRow(title: "동기화 대기", value: "\(knowledgeLog.pendingEventCount)건")
            UnifiedInfoRow(title: "마지막 동기화", value: lastSyncText)

            Toggle("새 기록 자동 동기화", isOn: $knowledgeLog.autoSyncEnabled)

            Button {
                Task { await knowledgeLog.syncNow() }
            } label: {
                HStack {
                    Image(systemName: knowledgeLog.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    Text(knowledgeLog.isSyncing ? "동기화 중" : "지금 동기화")
                    Spacer()
                }
            }
            .disabled(!knowledgeLog.isDestinationConfigured || knowledgeLog.isSyncing)

            if knowledgeLog.isDestinationConfigured {
                Button(role: .destructive) {
                    knowledgeLog.disconnectDestination()
                } label: {
                    Label("동기화 폴더 연결 해제", systemImage: "link.badge.minus")
                }
            }
        } header: {
            Text("개인 지식 로그")
        } footer: {
            Text("파일 앱에서 Google Drive 폴더를 선택하면 TurboMetaKnowledge 폴더 아래에 날짜별 Q&A가 저장됩니다. 사진, 음성, 위치, 인증값은 저장하지 않습니다.")
        }
    }

    private var integrationSection: some View {
        Section {
            UnifiedSettingsRow(
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

    #if DEBUG
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
                    Text(developerConsole.unreadErrorCount > 0
                         ? "오류 \(developerConsole.unreadErrorCount)개"
                         : "\(developerConsole.entries.count)줄")
                        .font(AppTypography.caption)
                        .foregroundColor(developerConsole.unreadErrorCount > 0 ? .red : AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textTertiary)
                }
            }

            UnifiedInfoRow(title: "진단 보고서", value: "사용자 선택 공유")
            UnifiedInfoRow(title: "자격 증명", value: "저장 전 마스킹")
        } header: {
            Text("개발자 진단")
        }
    }
    #endif

    private var aboutSection: some View {
        Section {
            UnifiedInfoRow(title: "settings.version".localized, value: "2.0.0")
            UnifiedInfoRow(title: "settings.sdkversion".localized, value: "0.5.0")
        } header: {
            Text("settings.about".localized)
        }
    }

    private func refreshAPIKeyStatus() {
        hasGoogleAPIKey = APIKeyManager.shared.hasGoogleAPIKey()
    }

    private func configureKnowledgeFolder(_ url: URL) {
        knowledgeLog.configureDestination(url)
    }

    private var lastSyncText: String {
        if knowledgeLog.isSyncing { return "진행 중" }
        guard let date = knowledgeLog.lastSyncDate else { return "아직 없음" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
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

private struct UnifiedInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            Text(value)
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct UnifiedSettingsRow: View {
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

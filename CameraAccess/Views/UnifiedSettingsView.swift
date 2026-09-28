/*
 * Google Gemini 단일 공급자와 지식 로그 동기화를 위한 사용자 설정 화면
 */

import MWDATCore
import SwiftUI

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

struct JevAPIKeySettingsView: View {
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
                    Text("TypeSafe Jev API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("settings.apikey.jev.help".localized)
                        Link(
                            "settings.apikey.jev.get".localized,
                            destination: URL(string: "https://typesafe.ai")!
                        )
                        .font(.caption)
                    }
                }

                Section {
                    Button("save".localized) { saveAPIKey() }
                        .frame(maxWidth: .infinity)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if APIKeyManager.shared.hasJevAPIKey() {
                        Button("settings.apikey.delete".localized, role: .destructive) {
                            deleteAPIKey()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("settings.jevkey.title".localized)
            .alert("save".localized, isPresented: $showSaveSuccess) {
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
                apiKey = APIKeyManager.shared.getJevAPIKey() ?? ""
            }
        }
    }

    private func saveAPIKey() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "settings.apikey.empty".localized
            showError = true
            return
        }

        if APIKeyManager.shared.saveJevAPIKey(apiKey) {
            showSaveSuccess = true
        } else {
            errorMessage = "settings.apikey.savefailed".localized
            showError = true
        }
    }

    private func deleteAPIKey() {
        if APIKeyManager.shared.deleteJevAPIKey() {
            apiKey = ""
            dismiss()
        } else {
            errorMessage = "settings.apikey.deletefailed".localized
            showError = true
        }
    }
}

struct UnifiedSettingsView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    #if DEBUG
    @ObservedObject private var developerConsole = DeveloperConsole.shared
    #endif
    @ObservedObject private var knowledgeLog = KnowledgeLogService.shared

    @State private var showGoogleAPIKeySettings = false
    @State private var showJevAPIKeySettings = false
    @State private var showVoiceEnrollment = false
    @State private var isVoiceEnrolled = VoiceEnrollmentStore.isEnrolled
    @State private var showKnowledgeFolderPicker = false
    @State private var showKnowledgeError = false
    @State private var knowledgeErrorMessage = ""

    @State private var hasGoogleAPIKey = false
    @State private var hasJevAPIKey = false
    @AppStorage(MeetingSceneMode.storageKey) private var sceneModeRaw = ""
    @AppStorage(MeetingMicMode.storageKey) private var micModeRaw = MeetingMicMode.phone.rawValue
    @AppStorage("meeting.voiceProcessingMode") private var voiceProcessing = "auto"
    @AppStorage(WhisperSide.storageKey) private var whisperSideRaw = WhisperSide.right.rawValue

    private var whisperSide: Binding<WhisperSide> {
        Binding(
            get: { WhisperSide.resolve(stored: whisperSideRaw) },
            set: { whisperSideRaw = $0.rawValue }
        )
    }

    private var micMode: Binding<MeetingMicMode> {
        Binding(
            get: { MeetingMicMode.resolve(stored: micModeRaw) },
            set: { micModeRaw = $0.rawValue }
        )
    }

    /// 저장값이 없으면 이전 켜기/끄기 스위치 값을 이어받는다.
    private var sceneMode: Binding<MeetingSceneMode> {
        Binding(
            get: {
                MeetingSceneMode.resolve(
                    stored: sceneModeRaw.isEmpty ? nil : sceneModeRaw,
                    legacyToggle: UserDefaults.standard.object(forKey: MeetingSceneMode.legacyToggleKey) as? Bool
                )
            },
            set: { sceneModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationView {
            List {
                deviceSection
                languageSection
                googleAISection
                jevSection
                knowledgeLogSection
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
            .sheet(isPresented: $showJevAPIKeySettings) {
                JevAPIKeySettingsView()
            }
            .onChange(of: showJevAPIKeySettings) { isShowing in
                if !isShowing { refreshAPIKeyStatus() }
            }
            .sheet(isPresented: $showVoiceEnrollment) {
                VoiceEnrollmentView()
            }
            .onChange(of: showVoiceEnrollment) { isShowing in
                if !isShowing { isVoiceEnrolled = VoiceEnrollmentStore.isEnrolled }
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
            Text("전사와 귓속말에 한국어를 사용합니다.")
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

            UnifiedInfoRow(title: "전사 모델", value: SpeakerDiarizationService.model)

            UnifiedInfoRow(
                title: "settings.quality".localized,
                value: "settings.quality.maximum".localized
            )

        } header: {
            Text("Google Gemini")
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

    private var jevSection: some View {
        Section {
            UnifiedSettingsRow(
                icon: "brain",
                iconColor: .indigo,
                title: "TypeSafe Jev API Key",
                value: hasJevAPIKey
                    ? "settings.apikey.configured".localized
                    : "settings.apikey.notconfigured".localized,
                valueColor: hasJevAPIKey ? .green : .red
            ) {
                showJevAPIKeySettings = true
            }

            UnifiedSettingsRow(
                icon: "person.wave.2",
                iconColor: .teal,
                title: "settings.voice".localized,
                value: isVoiceEnrolled
                    ? "settings.voice.enrolled".localized
                    : "settings.voice.missing".localized,
                valueColor: isVoiceEnrolled ? .green : .orange
            ) {
                showVoiceEnrollment = true
            }

            Picker("settings.whisper".localized, selection: whisperSide) {
                ForEach(WhisperSide.allCases) { side in
                    Text(side.titleKey.localized).tag(side)
                }
            }

            Picker(selection: sceneMode) {
                ForEach(MeetingSceneMode.allCases) { mode in
                    Text(mode.titleKey.localized).tag(mode)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.scene".localized)
                    Text(sceneMode.wrappedValue.detailKey.localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Picker(selection: micMode) {
                ForEach(MeetingMicMode.allCases) { mode in
                    Text(mode.titleKey.localized).tag(mode)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.mic".localized)
                    Text(micMode.wrappedValue.detailKey.localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Picker("음성처리 · 다음 대화부터 적용", selection: $voiceProcessing) {
                Text("자동").tag("auto")
                Text("켜짐").tag("on")
                Text("꺼짐").tag("off")
            }
        } header: {
            Text("회의 통역기")
        } footer: {
            Text("settings.apikey.jev.help".localized)
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
        hasJevAPIKey = APIKeyManager.shared.hasJevAPIKey()
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

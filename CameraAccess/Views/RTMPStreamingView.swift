/*
 * RTMP 라이브 송출 화면
 */

import SwiftUI

struct RTMPStreamingView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @StateObject private var rtmpViewModel = RTMPStreamingViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showUI = true
    @State private var frameTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let videoFrame = streamViewModel.currentVideoFrame {
                GeometryReader { geometry in
                    Image(uiImage: videoFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: AppSpacing.lg) {
                    ProgressView().scaleEffect(1.5).tint(.white)
                    Text("rtmp.connecting.video".localized)
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                }
            }

            if showUI {
                VStack(spacing: 0) {
                    headerView
                    Spacer()
                    if rtmpViewModel.isStreaming { statsView }
                    controlsView
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) { showUI.toggle() }
        }
        .onAppear {
            startVideoStream()
            rtmpViewModel.setStreamViewModel(streamViewModel)
        }
        .onDisappear { stopAll() }
        .sheet(isPresented: $rtmpViewModel.showSettings) {
            RTMPSettingsView(viewModel: rtmpViewModel)
        }
        .alert("error".localized, isPresented: $rtmpViewModel.showError) {
            Button("ok".localized) { rtmpViewModel.dismissError() }
        } message: {
            if let error = rtmpViewModel.errorMessage {
                Text(error)
            }
        }
    }

    private var headerView: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white)
            }
            .accessibilityLabel("닫기")

            Spacer()

            HStack(spacing: AppSpacing.sm) {
                Circle()
                    .fill(rtmpViewModel.connectionStatus.color)
                    .frame(width: 10, height: 10)
                Text(rtmpViewModel.connectionStatus.displayText)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
                if rtmpViewModel.isStreaming {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .modifier(BlinkingModifier())
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.black.opacity(0.6))
            .cornerRadius(AppCornerRadius.lg)

            Spacer()

            Button { rtmpViewModel.showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            .accessibilityLabel("송출 설정")
        }
        .padding(AppSpacing.md)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.7), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var statsView: some View {
        HStack(spacing: AppSpacing.lg) {
            StatItem(label: "초당 프레임", value: String(format: "%.1f", rtmpViewModel.currentFps))
            StatItem(label: "rtmp.frames".localized, value: "\(rtmpViewModel.framesSent)")
            StatItem(label: "rtmp.time".localized, value: formatTime(rtmpViewModel.connectionTime))
            StatItem(label: "rtmp.data".localized, value: formatBytes(rtmpViewModel.bytesSent))
        }
        .padding(AppSpacing.md)
        .background(Color.black.opacity(0.6))
        .cornerRadius(AppCornerRadius.md)
        .padding(.horizontal, AppSpacing.lg)
    }

    private var controlsView: some View {
        VStack(spacing: AppSpacing.md) {
            if !rtmpViewModel.isStreaming {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.sm) {
                        ForEach(RTMPStreamingViewModel.StreamingPlatform.allCases, id: \.self) { platform in
                            PlatformButton(
                                platform: platform,
                                isSelected: rtmpViewModel.selectedPlatform == platform
                            ) {
                                rtmpViewModel.selectPlatform(platform)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                }
            }

            if !rtmpViewModel.isStreaming && !rtmpViewModel.isConnecting {
                VStack(spacing: AppSpacing.sm) {
                    HStack {
                        Image(systemName: "link").foregroundColor(.white.opacity(0.6))
                        TextField("rtmp.url.placeholder".localized, text: $rtmpViewModel.rtmpUrl)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(AppSpacing.sm)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(AppCornerRadius.sm)

                    HStack {
                        Image(systemName: "key.fill").foregroundColor(.white.opacity(0.6))
                        SecureField("rtmp.key.placeholder".localized, text: $rtmpViewModel.streamKey)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                    }
                    .padding(AppSpacing.sm)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(AppCornerRadius.sm)

                    Label(
                        rtmpViewModel.transportSecurityText,
                        systemImage: rtmpViewModel.isEncryptedTransport ? "lock.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(rtmpViewModel.isEncryptedTransport ? .green : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, AppSpacing.lg)
            }

            Button {
                if rtmpViewModel.isStreaming {
                    rtmpViewModel.stopStreaming()
                } else {
                    rtmpViewModel.startStreaming()
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    if rtmpViewModel.isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: rtmpViewModel.isStreaming ? "stop.fill" : "video.fill")
                    }
                    Text(rtmpViewModel.isStreaming ? "rtmp.stop".localized : "rtmp.start".localized)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(rtmpViewModel.isStreaming ? Color.red : AppColors.primary)
                .foregroundColor(.white)
                .cornerRadius(AppCornerRadius.md)
            }
            .disabled(
                rtmpViewModel.isConnecting
                    || (rtmpViewModel.rtmpUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !rtmpViewModel.isStreaming)
            )
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.vertical, AppSpacing.lg)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func startVideoStream() {
        Task {
            print("[RTMPView][INFO] 안경 영상 스트림 시작 요청")
            await streamViewModel.handleStartStreaming()
        }

        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { _ in
            Task { @MainActor in
                if let frame = streamViewModel.currentVideoFrame {
                    let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000)
                    rtmpViewModel.feedFrame(frame, timestamp: timestamp)
                }
            }
        }
    }

    private func stopAll() {
        frameTimer?.invalidate()
        frameTimer = nil
        if rtmpViewModel.isStreaming { rtmpViewModel.stopStreaming() }

        Task {
            if streamViewModel.streamingStatus != .stopped {
                await streamViewModel.stopSession()
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        let remainingSeconds = Int(seconds) % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / (1_024 * 1_024)
        return megabytes >= 1_000
            ? String(format: "%.1f GB", megabytes / 1_024)
            : String(format: "%.1f MB", megabytes)
    }
}

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(AppTypography.headline).foregroundColor(.white)
            Text(label).font(AppTypography.caption).foregroundColor(.white.opacity(0.7))
        }
    }
}

struct PlatformButton: View {
    let platform: RTMPStreamingViewModel.StreamingPlatform
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: platform.icon).font(.system(size: 20))
                Text(platform.displayName).font(.caption2).lineLimit(1)
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.sm)
            .background(isSelected ? AppColors.primary : Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(AppCornerRadius.sm)
        }
    }
}

struct BlinkingModifier: ViewModifier {
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    isVisible.toggle()
                }
            }
    }
}

struct RTMPSettingsView: View {
    @ObservedObject var viewModel: RTMPStreamingViewModel
    @Environment(\.dismiss) private var dismiss

    private let bitrateOptions = [
        (1_000_000, "1 Mbps"),
        (2_000_000, "2 Mbps (권장)"),
        (3_000_000, "3 Mbps"),
        (4_000_000, "4 Mbps")
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(bitrateOptions, id: \.0) { option in
                        Button {
                            viewModel.bitrate = option.0
                        } label: {
                            HStack {
                                Text(option.1).foregroundColor(.primary)
                                Spacer()
                                if viewModel.bitrate == option.0 {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("rtmp.settings.bitrate".localized)
                } footer: {
                    Text("rtmp.settings.bitrate.description".localized)
                }

                Section {
                    ForEach(RTMPStreamingViewModel.StreamingPlatform.allCases, id: \.self) { platform in
                        Button {
                            viewModel.selectPlatform(platform)
                        } label: {
                            HStack {
                                Image(systemName: platform.icon).frame(width: 24)
                                Text(platform.displayName).foregroundColor(.primary)
                                Spacer()
                                if viewModel.selectedPlatform == platform {
                                    Image(systemName: "checkmark").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("rtmp.settings.platform".localized)
                }

                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("rtmp.settings.experimental".localized)
                            .font(AppTypography.headline)
                            .foregroundColor(.orange)
                        Text("rtmp.settings.experimental.description".localized)
                            .font(AppTypography.caption)
                            .foregroundColor(.secondary)
                        Text("스트림 키는 현재 iPhone 전용 Keychain에 저장되며 로그에 출력되지 않습니다.")
                            .font(AppTypography.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, AppSpacing.sm)
                } header: {
                    Text("rtmp.settings.note".localized)
                }
            }
            .navigationTitle("rtmp.settings".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
    }
}

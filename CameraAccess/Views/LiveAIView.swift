/*
 * 자동 시작형 실시간 AI 대화 화면
 */

import SwiftUI

struct LiveAIView: View {
    @StateObject private var viewModel: OmniRealtimeViewModel
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showConversation = true
    @State private var frameTimer: Timer?

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        // 선택한 제공자의 API Key만 사용하고 다른 서비스의 Key로 대체하지 않는다.
        self._viewModel = StateObject(
            wrappedValue: OmniRealtimeViewModel(apiKey: APIProviderManager.staticLiveAIAPIKey)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !streamViewModel.hasActiveDevice {
                deviceNotConnectedView
            } else {
                if let videoFrame = streamViewModel.currentVideoFrame {
                    GeometryReader { geometry in
                        Image(uiImage: videoFrame)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    headerView
                        .padding(.top, 8)

                    if showConversation {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.conversationHistory) { message in
                                        MessageBubble(message: message)
                                            .id(message.id)
                                    }

                                    if !viewModel.currentTranscript.isEmpty {
                                        MessageBubble(
                                            message: ConversationMessage(
                                                role: .assistant,
                                                content: viewModel.currentTranscript
                                            )
                                        )
                                        .id("current")
                                    }
                                }
                                .padding()
                            }
                            .onChange(of: viewModel.conversationHistory.count) { _ in
                                if let lastMessage = viewModel.conversationHistory.last {
                                    withAnimation {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                            .onChange(of: viewModel.currentTranscript) { _ in
                                withAnimation {
                                    proxy.scrollTo("current", anchor: .bottom)
                                }
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Spacer()
                    }

                    controlsView
                }
            }
        }
        .onAppear {
            guard streamViewModel.hasActiveDevice else {
                print("[LiveAIView][WARN] Ray-Ban Meta 안경이 연결되지 않아 시작 생략")
                return
            }

            Task {
                print("[LiveAIView][INFO] 안경 영상 스트림 시작 요청")
                await streamViewModel.handleStartStreaming()
            }

            viewModel.connect()

            frameTimer?.invalidate()
            frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if let frame = streamViewModel.currentVideoFrame {
                    viewModel.updateVideoFrame(frame)
                }
            }
        }
        .onDisappear {
            print("[LiveAIView][INFO] 실시간 AI 대화 및 영상 스트림 종료")
            frameTimer?.invalidate()
            frameTimer = nil
            viewModel.disconnect()

            Task {
                if streamViewModel.streamingStatus != .stopped {
                    await streamViewModel.stopSession()
                }
            }
        }
        .onChange(of: viewModel.isConnected) { isConnected in
            if isConnected, !viewModel.isRecording {
                viewModel.startRecording()
            }
        }
        .alert("error".localized, isPresented: $viewModel.showError) {
            Button("ok".localized) {
                viewModel.dismissError()
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    private var headerView: some View {
        HStack {
            Text("liveai.title".localized)
                .font(AppTypography.headline)
                .foregroundColor(.white)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showConversation.toggle()
                }
            } label: {
                Image(systemName: showConversation ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(showConversation ? "대화 내용 숨기기" : "대화 내용 보기")

            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isConnected ? "liveai.connected".localized : "liveai.connecting".localized)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
            }

            if viewModel.isSpeaking {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("liveai.speaking".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(Color.black.opacity(0.7))
    }

    private var controlsView: some View {
        VStack(spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.gray)
                    .frame(width: 8, height: 8)
                Text(viewModel.isRecording ? "liveai.listening".localized : "liveai.stop".localized)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.black.opacity(0.6))
            .cornerRadius(AppCornerRadius.xl)

            Button {
                viewModel.disconnect()
                dismiss()
            } label: {
                Label("liveai.stop".localized, systemImage: "stop.fill")
                    .font(AppTypography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.bottom, AppSpacing.lg)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var deviceNotConnectedView: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 80))
                    .foregroundColor(AppColors.liveAI.opacity(0.6))

                Text("liveai.device.notconnected.title".localized)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("liveai.device.notconnected.message".localized)
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Label("liveai.device.backtohome".localized, systemImage: "chevron.left")
                    .font(AppTypography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColors.primary)
                    .foregroundColor(.white)
                    .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
    }
}

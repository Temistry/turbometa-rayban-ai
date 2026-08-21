/*
 * 실시간 AI 음성 대화 화면
 */

import SwiftUI

struct OmniRealtimeView: View {
    @StateObject private var viewModel: OmniRealtimeViewModel
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var frameTimer: Timer?

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        self._viewModel = StateObject(wrappedValue: OmniRealtimeViewModel(apiKey: apiKey))
    }

    var body: some View {
        ZStack {
            if let videoFrame = streamViewModel.currentVideoFrame {
                Image(uiImage: videoFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .opacity(0.3)
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                headerView

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

                controlsView
            }
        }
        .onAppear {
            print("[OmniView][INFO] 실시간 AI 화면 열림")
            viewModel.connect()

            frameTimer?.invalidate()
            frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if let frame = streamViewModel.currentVideoFrame {
                    viewModel.updateVideoFrame(frame)
                }
            }
        }
        .onDisappear {
            print("[OmniView][INFO] 실시간 AI 화면 닫힘")
            frameTimer?.invalidate()
            frameTimer = nil
            viewModel.disconnect()
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
            Text("실시간 AI 대화")
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isConnected ? "연결됨" : "연결 안 됨")
                    .font(.caption)
                    .foregroundColor(.white)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.title2)
            }
            .accessibilityLabel("닫기")
        }
        .padding()
        .background(Color.black.opacity(0.7))
    }

    private var controlsView: some View {
        VStack(spacing: 12) {
            if viewModel.isSpeaking {
                Label("AI가 말하는 중...", systemImage: "waveform")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.2))
                    .cornerRadius(20)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRecording ? Color.red : Color.gray)
                    .frame(width: 8, height: 8)
                Text(viewModel.isRecording ? "듣는 중" : "마이크 중지됨")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(20)

            Button {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.isRecording ? "mic.fill" : "mic.slash.fill")
                        .font(.title)
                    Text(viewModel.isRecording ? "마이크 중지" : "마이크 시작")
                        .font(.caption)
                }
                .frame(width: 100, height: 80)
                .background(viewModel.isRecording ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
            .disabled(!viewModel.isConnected)
            .padding()
        }
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.blue : Color.gray.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(18)
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 4)
            }

            if message.role == .assistant { Spacer() }
        }
    }
}

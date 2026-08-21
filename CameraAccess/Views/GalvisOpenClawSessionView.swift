import SwiftUI

struct GalvisOpenClawSessionView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @StateObject private var sessionManager = GalvisOpenClawSessionManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer()

                Image(systemName: stateIcon)
                    .font(.system(size: 76))
                    .foregroundStyle(stateColor)
                    .symbolEffect(.pulse, isActive: isActiveState)

                Text("갈비스 · OpenClaw")
                    .font(.title.bold())

                Text(stateText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(stateColor)

                if !sessionManager.transcript.isEmpty {
                    Text("“\(sessionManager.transcript)”")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                if case .error(let message) = sessionManager.state {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Button("다시 시작") {
                        sessionManager.restartListening()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }

                if !openClawService.isGatewayTokenConfigured {
                    Label("OpenClaw 설정에서 Gateway 정보를 먼저 저장하세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                HStack(spacing: 12) {
                    NavigationLink {
                        OpenClawChatView(streamViewModel: streamViewModel)
                    } label: {
                        Label("채팅", systemImage: "text.bubble.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        stopAndDismiss()
                    } label: {
                        Label("대화 종료", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("갈비스")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("종료") { stopAndDismiss() }
                }
            }
        }
        .onAppear {
            openClawService.refreshGatewayTokenState()
            sessionManager.start()
        }
        .onDisappear { sessionManager.stop() }
    }

    private var stateText: String {
        switch sessionManager.state {
        case .idle: return "준비 중"
        case .requestingPermission: return "마이크 권한 확인 중"
        case .connecting: return "OpenClaw 연결 중"
        case .listening: return "듣는 중"
        case .waitingForResponse: return "OpenClaw 답변 대기 중"
        case .speaking: return "답변 중"
        case .recoveringAudio: return "마이크 복구 중"
        case .reconnecting: return "OpenClaw 재연결 중"
        case .error: return "음성 대화 오류"
        case .stopped: return "대화 종료됨"
        }
    }

    private var stateIcon: String {
        switch sessionManager.state {
        case .listening: return "mic.circle.fill"
        case .speaking: return "speaker.wave.3.fill"
        case .waitingForResponse, .connecting, .recoveringAudio, .reconnecting:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .idle, .requestingPermission: return "waveform.circle.fill"
        }
    }

    private var stateColor: Color {
        switch sessionManager.state {
        case .error: return .red
        case .stopped: return .secondary
        case .listening: return .green
        case .speaking: return .indigo
        case .recoveringAudio, .reconnecting: return .orange
        default: return .purple
        }
    }

    private var isActiveState: Bool {
        switch sessionManager.state {
        case .listening, .speaking, .connecting, .waitingForResponse, .recoveringAudio, .reconnecting:
            return true
        default:
            return false
        }
    }

    private func stopAndDismiss() {
        sessionManager.stop()
        dismiss()
    }
}

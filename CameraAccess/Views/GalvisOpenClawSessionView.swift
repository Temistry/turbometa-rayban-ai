import SwiftUI

struct GalvisOpenClawSessionView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.purple)

                Text("갈비스 · OpenClaw")
                    .font(.title.bold())

                statusView

                Text("음성 대화 준비 화면입니다. 다음 단계에서 마이크 인식, 짧은 답변 재생, 후속 질문 기능이 연결됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                if openClawService.loadGatewayToken() == nil {
                    Label("OpenClaw 설정에서 Gateway 정보를 먼저 저장하세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                NavigationLink {
                    OpenClawChatView(streamViewModel: streamViewModel)
                } label: {
                    Label("OpenClaw 채팅 열기", systemImage: "text.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .padding(.horizontal, 28)

                Spacer()
            }
            .navigationTitle("갈비스")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("종료") { dismiss() }
                }
            }
        }
        .onAppear {
            if openClawService.connectionState == .disconnected,
               openClawService.loadGatewayToken() != nil {
                openClawService.connect()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch openClawService.connectionState {
        case .connected:
            Label("OpenClaw 연결됨", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .connecting:
            Label("OpenClaw 연결 중", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .waitingForPairing:
            Label("기기 승인 대기 중", systemImage: "person.badge.clock.fill")
                .foregroundStyle(.orange)
        case .disconnected:
            Label("OpenClaw 연결 안 됨", systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
        case .error:
            Label("OpenClaw 연결 오류", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

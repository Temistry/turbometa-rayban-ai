import SwiftUI

struct MeetingStatusView: View {
    @StateObject private var link = PhoneLink()

    private var stateColor: Color {
        if !link.error.isEmpty { return .red }
        return link.state == "listening" ? .green : .gray
    }

    private var stateLabel: String {
        if !link.error.isEmpty { return "중지됨" }
        return link.state == "listening" ? "듣는 중" : "대기"
    }

    private var captureTitle: String {
        switch link.captureFeedback {
        case .sending: return "보내는 중"
        case .accepted: return "보는 중"
        case .busy: return "잠시 후 다시"
        case .unreachable: return "폰 연결 안 됨"
        case .unavailable: return "폰에서 앱 열기"
        case .failed: return "촬영 실패"
        case .idle:
            if link.scene == WatchMeetingStatus.sceneWorking { return "보는 중" }
            if link.scene == WatchMeetingStatus.sceneFailed { return "다시 촬영" }
            return "장면 설명"
        }
    }

    private var captureTint: Color {
        switch link.captureFeedback {
        case .busy, .unreachable, .unavailable, .failed: return .orange
        default: return .blue
        }
    }

    private var captureDisabled: Bool {
        link.captureFeedback == .sending || link.scene == WatchMeetingStatus.sceneWorking
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Text(stateLabel)
                        .font(.headline)
                    Spacer()
                    if let startedAt = link.startedAt, link.state == "listening" {
                        Text(Self.elapsedText(since: startedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(link.route)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if link.quotaPaused {
                    Label("설명 재개 대기 중 · 자막은 계속", systemImage: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(link.recent.suffix(3).enumerated().reversed()), id: \.offset) { _, text in
                        Text(text)
                            .font(.footnote)
                    }
                }

                if !link.error.isEmpty {
                    Text(link.error)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.red)
                }

                Text("귓속말 \(link.whisperCount)회")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        // 화면을 보지 않고도 누를 수 있게 스크롤과 무관하게 아래에 고정한다.
        .safeAreaInset(edge: .bottom) {
            Button(action: link.requestCapture) {
                Label(captureTitle, systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(captureTint)
            .disabled(captureDisabled)
        }
        .navigationTitle("TurboMeta")
        .onAppear { link.activate() }
    }

    static func elapsedText(since date: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(date)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

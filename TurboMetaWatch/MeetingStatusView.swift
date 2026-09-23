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
        .navigationTitle("TurboMeta")
        .onAppear { link.activate() }
    }

    static func elapsedText(since date: Date) -> String {
        let total = max(0, Int(Date().timeIntervalSince(date)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

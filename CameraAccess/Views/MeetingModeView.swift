/*
 * 회의 통역기 화면
 *
 * 실시간 전사 스트림 + 자동 귓속말 표시 + 근거 조사 링크 카드.
 * Jev 장애 시 에러 코드를 표시하고 통역을 정지한다(fail-stop).
 */

import SwiftUI

struct MeetingModeView: View {
    @StateObject private var viewModel = MeetingInterpreterViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure = viewModel.failure {
                MeetingErrorView(failure: failure) {
                    viewModel.stop()
                    dismiss()
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            if viewModel.lines.isEmpty && viewModel.factCards.isEmpty {
                Spacer()
                Text("meeting.empty".localized)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.factCards) { card in
                                MeetingFactCardView(card: card)
                            }
                            ForEach(viewModel.lines) { line in
                                MeetingTranscriptRowView(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: viewModel.lines.count) { _, _ in
                        guard let last = viewModel.lines.last else { return }
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("meeting.title".localized)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("meeting.route.format".localized(viewModel.inputRouteName))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            MeetingStatusDot(label: "meeting.dot.transcription".localized, isOn: viewModel.runState == .listening)
            MeetingStatusDot(label: "meeting.dot.jev".localized, isOn: viewModel.jevReady)
            MeetingStatusDot(label: "meeting.dot.whisper".localized, isOn: viewModel.isSpeakingWhisper)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        Button {
            if viewModel.runState == .listening {
                viewModel.stop()
            } else {
                viewModel.start()
            }
        } label: {
            Text(viewModel.runState == .listening ? "meeting.stop".localized : "meeting.start".localized)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            viewModel.runState == .listening
                                ? Color.red.opacity(0.75)
                                : Color.blue.opacity(0.75)
                        )
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct MeetingStatusDot: View {
    let label: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOn ? Color.green : Color.white.opacity(0.25))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

private struct MeetingTranscriptRowView: View {
    let line: MeetingInterpreterViewModel.TranscriptLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(line.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
            }
            Text(line.text)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))

            if let whisper = line.whisper {
                if whisper.text.isEmpty {
                    Label("meeting.whisper.failed".localized, systemImage: "speaker.slash.fill")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.9))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: whisper.state == .speaking ? "speaker.wave.2.fill" : "speaker.wave.1.fill")
                            .font(.caption)
                        Text(whisper.text)
                            .font(.caption)
                        Text(String(format: "%.2f", whisper.confidence))
                            .font(.caption2)
                            .opacity(0.65)
                    }
                    .foregroundColor(whisper.state == .failed ? .red.opacity(0.9) : Color(red: 0.45, green: 0.66, blue: 1))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
    }
}

private struct MeetingFactCardView: View {
    let card: MeetingInterpreterViewModel.FactCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Text("meeting.fact.card".localized)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                if card.state == .pending {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                }
            }

            Text("\(card.claim)")
                .font(.subheadline)
                .italic()
                .foregroundColor(.white.opacity(0.9))

            switch card.state {
            case .pending:
                Text("meeting.fact.pending".localized)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            case .failed:
                Text("meeting.fact.failed".localized)
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.9))
            case .done:
                if let summary = card.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                ForEach(card.links) { link in
                    if let url = URL(string: link.urlString) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                Text(link.title)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundColor(Color(red: 0.45, green: 0.66, blue: 1))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.35))
        )
    }
}

private struct MeetingErrorView: View {
    let failure: MeetingInterpreterViewModel.Failure
    var onDismiss: () -> Void

    private var codeText: String {
        switch failure {
        case .jev(let code, _):
            return code
        case .microphone:
            return "E-MIC-503"
        }
    }

    private var messageText: String {
        switch failure {
        case .jev(_, let message):
            return message
        case .microphone(let message):
            return message
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.red)
            Text(codeText)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundColor(.red)
            Text("meeting.error.title".localized)
                .font(.headline)
                .foregroundColor(.white)
            VStack(spacing: 6) {
                Text(messageText)
                Text("meeting.error.action".localized)
                Text("meeting.error.restart".localized)
            }
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.center)

            Button(action: onDismiss) {
                Text("meeting.error.close".localized)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.55))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(28)
    }
}

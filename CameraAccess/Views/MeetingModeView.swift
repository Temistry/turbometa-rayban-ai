/*
 * 회의 통역기 화면(단일 목적 캡션 스트림)
 *
 * 라이브 캡션이 히어로. 안내 문장 없이 상태 칩과 컨트롤만 남긴다.
 * 근거 조사는 배지 → 하프시트, 오류는 코드 + 한 줄 + 닫기.
 */

import SwiftUI

struct MeetingModeView: View {
    @StateObject private var viewModel: MeetingInterpreterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showArchive = false
    @State private var showFactSheet = false
    @State private var isFollowing = true

    init(streamViewModel: StreamSessionViewModel) {
        _viewModel = StateObject(
            wrappedValue: MeetingInterpreterViewModel(streamViewModel: streamViewModel)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if viewModel.runState == .listening || !viewModel.lines.isEmpty {
                    captionArea
                } else {
                    idleArea
                }
                cameraBar
            }

            if let failure = viewModel.failure {
                MeetingErrorOverlay(failure: failure) {
                    viewModel.stop()
                    dismiss()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let bubble = viewModel.detailBubble {
                MeetingDetailBubble(bubble: bubble) {
                    viewModel.closeDetail()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 158)
            }
        }
        .sheet(isPresented: $showFactSheet) {
            MeetingFactSheet(cards: viewModel.factCards)
        }
        .sheet(isPresented: $showSettings) {
            NavigationView {
                UnifiedSettingsView(streamViewModel: viewModel.streamViewModel)
            }
        }
        .sheet(isPresented: $showArchive) {
            NavigationView {
                MeetingArchiveListView()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            MeetingChip(
                text: viewModel.runState == .listening
                    ? "meeting.status.listening".localized
                    : "meeting.status.idle".localized,
                color: viewModel.runState == .listening ? .green : .gray
            )
            if viewModel.runState == .listening {
                MeetingChip(text: viewModel.inputRouteName, color: .blue)
            }

            Spacer()

            Button {
                showArchive = true
            } label: {
                Image(systemName: "archivebox")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
            }
            .accessibilityLabel("meeting.archive.title".localized)
            .padding(.trailing, 2)

            if !viewModel.factCards.isEmpty {
                Button {
                    showFactSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal")
                        Text("\(viewModel.factCards.count)")
                            .monospacedDigit()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.blue.opacity(0.55)))
                }
                .accessibilityLabel("meeting.fact.badge".localized)
            }

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
            }
            .accessibilityLabel("settings.title".localized)
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var idleArea: some View {
        VStack(spacing: 20) {
            Spacer()
            Button {
                viewModel.start()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 92, height: 92)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
            }
            .accessibilityLabel("meeting.start".localized)
            .disabled(viewModel.isStarting || viewModel.isStopping || viewModel.isDescribingPhoto || viewModel.isSpeakingWhisper)

            Text("meeting.start".localized)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.55))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captionArea: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(viewModel.lines) { line in
                            MeetingCaptionRow(line: line)
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.handleLineTap(line.id)
                                }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .simultaneousGesture(
                    DragGesture().onChanged { value in
                        if value.translation.height > 24 {
                            isFollowing = false
                        }
                    }
                )
                .onChange(of: viewModel.lines) { _, _ in
                    guard isFollowing, let last = viewModel.lines.last else { return }
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowing {
                        Button {
                            isFollowing = true
                            if let last = viewModel.lines.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        } label: {
                            Text("meeting.latest".localized)
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.white.opacity(0.18)))
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 10)
                    }
                }
            }

            if viewModel.runState == .listening || viewModel.isDescribingPhoto || viewModel.isSpeakingWhisper {
                stopBar
            } else {
                Button("meeting.start".localized) { viewModel.start() }
                    .disabled(viewModel.isStarting || viewModel.isStopping || viewModel.isDescribingPhoto || viewModel.isSpeakingWhisper)
                    .padding()
            }
        }
    }

    private var stopBar: some View {
        Button {
            viewModel.stop()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                Text("meeting.stop".localized)
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(Color.red.opacity(0.65)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cameraBar: some View {
        VStack(spacing: 8) {
            if viewModel.runState == .idle, viewModel.lines.isEmpty, viewModel.isDescribingPhoto {
                Button("meeting.stop".localized) { viewModel.stop() }
                    .padding(12)
            }
            if let error = viewModel.photoError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            Button {
                viewModel.describeCurrentScene()
            } label: {
                HStack(spacing: 12) {
                    if viewModel.isDescribingPhoto {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "camera.fill").font(.title)
                    }
                    Text(viewModel.isDescribingPhoto
                         ? "meeting.photo.busy".localized
                         : "meeting.photo.capture".localized)
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 104)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.blue.opacity(0.8)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isStarting || viewModel.isStopping || viewModel.isDescribingPhoto || viewModel.isSpeakingWhisper)
            .accessibilityLabel("meeting.photo.capture".localized)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

private struct MeetingChip: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

private struct MeetingCaptionRow: View {
    let line: MeetingInterpreterViewModel.TranscriptLine

    private var bodyText: Text {
        if let whisper = line.whisper,
           !whisper.term.isEmpty,
           let range = line.text.range(of: whisper.term, options: .caseInsensitive) {
            return
                Text(line.text[..<range.lowerBound])
                + Text(whisper.term)
                    .foregroundColor(.yellow)
                    .underline(color: .yellow.opacity(0.7))
                + Text(line.text[range.upperBound...])
        }
        return Text(line.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bodyText
                .font(.system(size: 15.5))
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            if let whisper = line.whisper {
                if whisper.state == .failed {
                    Label("meeting.whisper.failed".localized, systemImage: "speaker.slash.fill")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.85))
                } else if !whisper.text.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: whisper.state == .speaking ? "speaker.wave.2.fill" : "ear")
                            .font(.caption)
                        if !whisper.category.isEmpty {
                            Text(whisper.category == "business" ? "비즈니스" : "개발")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        Text(whisper.text)
                            .font(.footnote)
                    }
                    .foregroundColor(Color(red: 0.45, green: 0.66, blue: 1))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Text(card.claim)
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

private struct MeetingFactSheet: View {
    let cards: [MeetingInterpreterViewModel.FactCard]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(cards) { card in
                        MeetingFactCardView(card: card)
                    }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("meeting.fact.card".localized)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

private struct MeetingErrorOverlay: View {
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(codeText)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundColor(.red)
                Text("meeting.error.short".localized)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))

                Button(action: onDismiss) {
                    Text("meeting.error.close".localized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.red.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(28)
        }
    }
}

private struct MeetingDetailBubble: View {
    let bubble: MeetingInterpreterViewModel.DetailBubble
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(bubble.query)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.5))
                }
                .accessibilityLabel("meeting.detail.close".localized)
            }

            switch bubble.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().tint(.white.opacity(0.7))
                    Text("meeting.detail.loading".localized)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.75))
                }
            case .failed:
                Text("meeting.detail.failed".localized)
                    .font(.footnote)
                    .foregroundColor(.orange)
            case .ready(let message, let links):
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(links) { link in
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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.12).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18))
        )
    }
}

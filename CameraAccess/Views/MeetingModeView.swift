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
    @State private var catchFilter: CatchKind?

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
                filterBar
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
            MeetingFactSheet(catches: viewModel.catches, cards: viewModel.factCards)
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
        .sheet(isPresented: summaryPresented) {
            if let report = viewModel.summaryReport {
                MeetingSummaryReportView(report: report) {
                    viewModel.dismissSummary()
                }
            }
        }
    }

    private var summaryPresented: Binding<Bool> {
        Binding(
            get: { viewModel.summaryReport != nil },
            set: { if !$0 { viewModel.dismissSummary() } }
        )
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
            if viewModel.runState == .listening, let startedAt = viewModel.conversationStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    MeetingChip(
                        text: Self.elapsedText(Date().timeIntervalSince(startedAt)),
                        color: .white
                    )
                }
            }
            MeetingChip(
                text: viewModel.voiceEnrolled
                    ? "meeting.voice.enrolled".localized
                    : "meeting.voice.none".localized,
                color: viewModel.voiceEnrolled ? .green : .gray
            )

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

            if !viewModel.factCards.isEmpty || !viewModel.catches.isEmpty {
                Button {
                    showFactSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.bubble")
                        Text("\(viewModel.factCards.count + viewModel.catches.count)")
                            .monospacedDigit()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange.opacity(0.6)))
                }
                .accessibilityLabel("meeting.catch.title".localized)
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

    private var catchCounts: [CatchKind: Int] {
        Dictionary(grouping: viewModel.catches, by: \.kind).mapValues(\.count)
    }

    @ViewBuilder
    private var filterBar: some View {
        let counts = catchCounts
        if !counts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(kind: nil, label: "meeting.filter.all".localized, count: viewModel.catches.count)
                    ForEach(CatchKind.allCases.filter { counts[$0] != nil }, id: \.self) { kind in
                        filterChip(kind: kind, label: kind.titleKey.localized, count: counts[kind] ?? 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private func filterChip(kind: CatchKind?, label: String, count: Int) -> some View {
        let isActive = catchFilter == kind
        let tint = kind?.color ?? .white
        return Button {
            withAnimation { catchFilter = kind }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(isActive ? .black : .white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(isActive ? tint : Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(tint.opacity(isActive ? 0 : 0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(count)")
    }

    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
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
                        ForEach(visibleEntries) { entry in
                            MeetingCaptionRow(line: entry.line, associated: entry.associated)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.handleLineTap(entry.line.id)
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
                    guard isFollowing, let last = visibleEntries.last else { return }
                    withAnimation {
                        proxy.scrollTo(last.line.id, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowing {
                        Button {
                            isFollowing = true
                            if let last = visibleEntries.last {
                                withAnimation {
                                    proxy.scrollTo(last.line.id, anchor: .bottom)
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

    private struct CaptionEntry: Identifiable {
        let line: MeetingInterpreterViewModel.TranscriptLine
        let associated: [ConversationCatch]
        var id: UUID { line.id }
    }

    /// 전사문마다 겹치는 잡아낸 항목을 붙이고, 필터가 있으면 해당 종류만 남긴다.
    private var visibleEntries: [CaptionEntry] {
        let all = viewModel.lines.map { line in
            CaptionEntry(
                line: line,
                associated: viewModel.catches.filter {
                    CatchHighlighter.isAssociated(lineText: line.text, quote: $0.quote)
                }
            )
        }
        guard let catchFilter else { return all }
        return all.filter { entry in
            entry.associated.contains { $0.kind == catchFilter }
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
    let associated: [ConversationCatch]

    private struct Highlight {
        let lower: Int
        let upper: Int
        let color: Color
    }

    /// 잡아낸 단어(종류색) + 전문용어(노랑). 겹치면 잡아낸 쪽을 우선한다.
    private var highlights: [Highlight] {
        var result: [Highlight] = []
        var taken: [Range<Int>] = []
        for item in associated {
            for mark in CatchHighlighter.marks(in: line.text, quote: item.quote, kind: item.kind) {
                guard !taken.contains(where: {
                    mark.lowerOffset < $0.upperBound && mark.upperOffset > $0.lowerBound
                }) else { continue }
                taken.append(mark.lowerOffset..<mark.upperOffset)
                result.append(Highlight(lower: mark.lowerOffset, upper: mark.upperOffset, color: item.kind.color))
            }
        }
        if let whisper = line.whisper,
           !whisper.term.isEmpty,
           let range = line.text.range(of: whisper.term, options: .caseInsensitive) {
            let lower = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
            let upper = line.text.distance(from: line.text.startIndex, to: range.upperBound)
            if !taken.contains(where: { lower < $0.upperBound && upper > $0.lowerBound }) {
                result.append(Highlight(lower: lower, upper: upper, color: .yellow))
            }
        }
        return result.sorted { $0.lower < $1.lower }
    }

    private var bodyText: Text {
        let marks = highlights
        guard !marks.isEmpty else { return Text(line.text) }
        var result = Text("")
        var cursor = line.text.startIndex
        for mark in marks {
            let lower = line.text.index(line.text.startIndex, offsetBy: mark.lower)
            let upper = line.text.index(line.text.startIndex, offsetBy: mark.upper)
            if cursor < lower {
                result = result + Text(line.text[cursor..<lower])
            }
            result = result + Text(line.text[lower..<upper])
                .foregroundColor(mark.color)
                .underline(color: mark.color.opacity(0.65))
            cursor = upper
        }
        if cursor < line.text.endIndex {
            result = result + Text(line.text[cursor...])
        }
        return result
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

            ForEach(associated) { item in
                MeetingInlineCatchRow(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CatchKind {
    var color: Color {
        switch self {
        case .unsupported: return .orange
        case .leap: return .purple
        case .contradiction: return .red
        case .claim: return Color(red: 0.35, green: 0.6, blue: 1)
        }
    }
}

private struct MeetingInlineCatchRow: View {
    let item: ConversationCatch

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: item.kind.symbol)
                    .font(.caption2)
                Text(item.kind.titleKey.localized)
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text(item.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
            }
            .foregroundColor(item.kind.color)
            Text(item.point)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.92))
            if !item.ask.isEmpty {
                Label(item.ask, systemImage: "arrowshape.turn.up.left")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(item.kind.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.kind.color.opacity(0.35)))
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
    let catches: [ConversationCatch]
    let cards: [MeetingInterpreterViewModel.FactCard]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(catches) { item in
                        MeetingCatchCardView(item: item)
                    }
                    ForEach(cards) { card in
                        MeetingFactCardView(card: card)
                    }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("meeting.catch.title".localized)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

private struct MeetingCatchCardView: View {
    let item: ConversationCatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.symbol)
                Text(item.kind.titleKey.localized)
                Spacer()
                Text(item.timestamp, style: .time)
                    .foregroundColor(.white.opacity(0.5))
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(item.kind.color)

            if !item.quote.isEmpty {
                Text("“\(item.quote)”")
                    .font(.subheadline)
                    .italic()
                    .foregroundColor(.white.opacity(0.9))
            }
            Text(item.point)
                .font(.subheadline)
                .foregroundColor(.white)
            if !item.ask.isEmpty {
                Label(item.ask, systemImage: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(item.kind.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(item.kind.color.opacity(0.4)))
    }
}

private struct MeetingSummaryReportView: View {
    let report: MeetingSummaryBuilder.Summary
    var onDone: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        stat(title: "meeting.summary.duration".localized,
                             value: MeetingArchiveService.offsetText(report.duration))
                        stat(title: "meeting.summary.lines".localized,
                             value: "\(report.lineCount)")
                        stat(title: "meeting.summary.catches".localized,
                             value: "\(report.catches.count)")
                        stat(title: "meeting.summary.cost".localized,
                             value: String(format: "$%.4f", report.cost))
                    }

                    if report.catches.isEmpty {
                        Text("meeting.catch.none".localized)
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(report.catches) { item in
                            MeetingCatchCardView(item: item)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("meeting.summary.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("meeting.summary.done".localized, action: onDone)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: MeetingSummaryBuilder.exportText(report)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("meeting.summary.share".localized)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
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

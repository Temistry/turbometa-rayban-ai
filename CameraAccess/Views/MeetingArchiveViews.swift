/*
 * 회의 서랍 화면
 *
 * 보관된 회의(음성 원본 + 전사 텍스트) 목록과 상세 보기,
 * 텍스트/음성 내보내기, 삭제를 담당한다.
 */

import SwiftUI
import AVFoundation

struct MeetingArchiveListView: View {
    @StateObject private var archive = MeetingArchiveService()
    @State private var meetings: [ArchivedMeeting] = []
    @State private var search = ""

    private var filteredMeetings: [ArchivedMeeting] {
        guard !search.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.lines.contains { $0.text.localizedCaseInsensitiveContains(search) }
                || (meeting.catches ?? []).contains { $0.point.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        Group {
            if meetings.isEmpty {
                Text("meeting.archive.empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(filteredMeetings) { meeting in
                        NavigationLink {
                            MeetingArchiveDetailView(meeting: meeting)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.title(meeting.startedAt))
                                    .font(.subheadline.weight(.semibold))
                                Text((meeting.mode ?? .realtime).title + " · " +
                                     (meeting.processingState?.title ?? "기록"))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let endedAt = meeting.endedAt {
                                    Text(MeetingArchiveService.offsetText(endedAt.timeIntervalSince(meeting.startedAt)))
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                if meeting.recovered == true {
                                    Text("중단된 기록 복구됨").font(.caption2).foregroundStyle(.orange)
                                }
                                if let catches = meeting.catches, !catches.isEmpty {
                                    Text("meeting.catch.count".localized(catches.count))
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                                Text(meeting.lines.first?.text ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("meeting.archive.title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "전사·감지 내용 검색")
        .toolbar {
            if !meetings.isEmpty {
                ShareLink(item: meetings.map(MeetingArchiveService.exportText).joined(separator: "\n\n")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("meeting.archive.exportAll".localized)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        archive.recoverInterruptedRecordings()
        meetings = archive.loadAll()
    }

    private func delete(at offsets: IndexSet) {
        offsets.map { filteredMeetings[$0].id }.forEach { archive.delete(id: $0) }
        reload()
    }

    static func title(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct MeetingArchiveDetailView: View {
    @State var meeting: ArchivedMeeting
    @State private var confirmProcessing = false
    @State private var processing = false
    @State private var processingError: String?
    @State private var processingTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var archive = MeetingArchiveService()
    @StateObject private var playback = ArchiveAudioPlayback()
    @State private var selectedLine: ArchivedMeetingLine?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(playback.isPlaying ? "재생 중지" : "원본 듣기") {
                        if playback.isPlaying { playback.stop() }
                        else { play(at: 0) }
                    }
                    .disabled(MeetingInterpreterViewModel.isConversationActive)
                    if let error = playback.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                if meeting.mode == .passive {
                    Text((meeting.processingState ?? .unprocessed).title)
                        .font(.caption).foregroundStyle(.secondary)
                    if meeting.processingState != .completed {
                        Button(processing ? "처리 중" : "전사·분석하기") { confirmProcessing = true }
                            .disabled(processing || MeetingInterpreterViewModel.isConversationActive)
                    }
                    if processing {
                        ProgressView()
                        Text("전사 \(meeting.transcribedUnits?.count ?? 0)구간 · 분석 \(meeting.analyzedLines?.count ?? 0)/\(meeting.lines.count)문장")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("처리 중단") { processingTask?.cancel() }
                    }
                    if let processingError {
                        Text(processingError).font(.caption).foregroundStyle(.orange)
                    }
                }
                if let catches = meeting.catches, !catches.isEmpty {
                    ForEach(catches) { item in
                        ArchivedCatchRow(item: item)
                    }
                }
                ForEach(meeting.lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MeetingArchiveService.offsetText(line.offset))
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                        Text(line.text)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedLine = line }
                        if let whisper = line.whisper {
                            let termLabel = line.term.map { $0 + " · " } ?? ""
                            Text("귓속말: " + termLabel + whisper)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        ForEach(line.sourceURLs ?? [], id: \.self) { source in
                            if let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") {
                                Link(url.host ?? source, destination: url)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(MeetingArchiveListView.title(meeting.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { playback.stop(); processingTask?.cancel() }
        .sheet(item: $selectedLine) { line in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(line.text).font(.headline)
                    Button("이 구간 듣기") { play(at: line.offset) }
                        .disabled(MeetingInterpreterViewModel.isConversationActive)
                    if let explanation = line.whisper, !explanation.isEmpty {
                        Text(explanation)
                        Button("설명 읽어주기") { playback.speak(explanation) }
                            .disabled(MeetingInterpreterViewModel.isConversationActive)
                    }
                    ForEach(line.sourceURLs ?? [], id: \.self) { source in
                        if let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") {
                            Link(source, destination: url)
                        }
                    }
                    Button("재생 중지") { playback.stop() }
                }.padding()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("녹음을 외부 AI 서비스로 보내 전사·분석할까요?", isPresented: $confirmProcessing,
                            titleVisibility: .visible) {
            Button("전사·분석하기") {
                processing = true
                processingError = nil
                processingTask = Task {
                    defer { processing = false; processingTask = nil }
                    do {
                        try await archive.process(meeting) { meeting = $0 }
                    } catch {
                        if let jevError = error as? JevClientError {
                            processingError = "\(jevError.code) · \(jevError.message)"
                        } else {
                            processingError = Task.isCancelled
                                ? "중단됨 · 완료 구간은 보관했습니다."
                                : "처리 실패 · 저장된 구간부터 다시 시도할 수 있습니다."
                        }
                    }
                }
            }
        }
        .toolbar {
            ShareLink(item: MeetingArchiveService.exportText(meeting)) {
                Image(systemName: "text.quote")
            }
            .accessibilityLabel("meeting.archive.exportText".localized)

            if !archive.audioFileURLs(id: meeting.id).isEmpty {
                ShareLink(items: archive.audioFileURLs(id: meeting.id)) {
                    Image(systemName: "waveform")
                }
                .accessibilityLabel("meeting.archive.exportAudio".localized)
            }

            Button(role: .destructive) {
                archive.delete(id: meeting.id)
                dismiss()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("meeting.archive.delete".localized)
            .disabled(processing || archive.isBusy(id: meeting.id))
        }
    }

    private func play(at offset: TimeInterval) {
        playback.play(folder: archive.sessionURL(id: meeting.id),
                      chunks: archive.audioChunks(for: meeting), offset: offset)
    }
}

@MainActor
private final class ArchiveAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var chunks: [ArchivedAudioChunk] = []
    private var folder: URL?
    private var index = 0
    private var ownsSpeech = false

    func play(folder: URL, chunks: [ArchivedAudioChunk], offset: TimeInterval) {
        guard !MeetingInterpreterViewModel.isConversationActive else { return }
        stop()
        error = nil
        self.folder = folder
        self.chunks = chunks.sorted { $0.offset < $1.offset }
        guard let selected = self.chunks.firstIndex(where: { $0.offset + $0.duration > offset }) else {
            error = "재생할 음성이 없습니다."
            return
        }
        index = selected
        startChunk(at: max(0, offset - self.chunks[selected].offset))
    }

    private func startChunk(at offset: TimeInterval = 0) {
        guard let folder, chunks.indices.contains(index) else { stop(); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let next = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(chunks[index].filename))
            player = next
            next.delegate = self
            next.currentTime = offset
            guard next.play() else { throw CocoaError(.fileReadCorruptFile) }
            isPlaying = true
        } catch {
            self.error = "음성을 재생하지 못했습니다."
            stop()
        }
    }

    func speak(_ text: String) {
        guard !MeetingInterpreterViewModel.isConversationActive else { return }
        stop()
        ownsSpeech = TTSService.shared.enqueue(text, volume: 0.35, pan: WhisperSide.current.pan) != nil
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        if ownsSpeech { TTSService.shared.stop(); ownsSpeech = false }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if flag { self.index += 1; self.startChunk() }
            else { self.error = "음성 재생이 중단됐습니다."; self.stop() }
        }
    }
}

private struct ArchivedCatchRow: View {
    let item: ArchivedMeetingCatch

    private var kind: CatchKind? { CatchKind(rawValue: item.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: kind?.symbol ?? "exclamationmark.bubble")
                    .font(.caption2)
                Text(kind?.titleKey.localized ?? item.kind)
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text(MeetingArchiveService.offsetText(item.offset))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }
            .foregroundColor(kind?.color ?? .orange)
            if !item.quote.isEmpty {
                Text(item.quote)
                    .font(.footnote)
                    .italic()
                    .foregroundColor(.secondary)
            }
            Text(item.point)
                .font(.footnote)
            if !item.ask.isEmpty {
                Text(item.ask)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((kind?.color ?? .orange).opacity(0.10))
        )
    }
}

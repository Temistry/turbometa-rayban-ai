/*
 * 회의 서랍 화면
 *
 * 보관된 회의(음성 원본 + 전사 텍스트) 목록과 상세 보기,
 * 텍스트/음성 내보내기, 삭제를 담당한다.
 */

import SwiftUI

struct MeetingArchiveListView: View {
    @StateObject private var archive = MeetingArchiveService()
    @State private var meetings: [ArchivedMeeting] = []

    var body: some View {
        Group {
            if meetings.isEmpty {
                Text("meeting.archive.empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(meetings) { meeting in
                        NavigationLink {
                            MeetingArchiveDetailView(meeting: meeting)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.title(meeting.startedAt))
                                    .font(.subheadline.weight(.semibold))
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
        .toolbar {
            if !meetings.isEmpty {
                ShareLink(item: meetings.map(MeetingArchiveService.exportText).joined(separator: "\n\n")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("meeting.archive.exportAll".localized)
            }
        }
        .task { reload() }
    }

    private func reload() {
        meetings = archive.loadAll()
    }

    private func delete(at offsets: IndexSet) {
        offsets.map { meetings[$0].id }.forEach { archive.delete(id: $0) }
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
    let meeting: ArchivedMeeting
    @Environment(\.dismiss) private var dismiss
    @StateObject private var archive = MeetingArchiveService()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
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
                        if let whisper = line.whisper {
                            let termLabel = line.term.map { $0 + " · " } ?? ""
                            Text("귓속말: " + termLabel + whisper)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(MeetingArchiveListView.title(meeting.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: MeetingArchiveService.exportText(meeting)) {
                Image(systemName: "text.quote")
            }
            .accessibilityLabel("meeting.archive.exportText".localized)

            if let audioURL = archive.audioFileURL(id: meeting.id) {
                ShareLink(item: audioURL) {
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

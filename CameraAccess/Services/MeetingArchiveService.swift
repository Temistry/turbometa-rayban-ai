/*
 * 회의 녹취록 보관 서비스
 *
 * 세션마다 폴더를 만들어 음성 원본(audio.caf)과 전사 텍스트(transcript.json)를
 * 함께 보관한다. 파일은 앱 전용 문서 폴더에 파일 보호(.complete)로 저장하며
 * 외부 반출은 사용자가 공유 버튼으로 직접 선택할 때만 일어난다.
 */

import Foundation

struct ArchivedMeetingLine: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 세션 시작 대비 초 단위 오프셋.
    let offset: TimeInterval
    let text: String
    var term: String?
    var whisper: String?
}

struct ArchivedMeeting: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var lines: [ArchivedMeetingLine]
}

@MainActor
final class MeetingArchiveService {
    private let fileManager = FileManager.default
    private let rootOverride: URL?

    init(rootURL: URL? = nil) {
        self.rootOverride = rootURL
    }

    var rootURL: URL {
        if let rootOverride { return rootOverride }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MeetingArchive", isDirectory: true)
    }

    func sessionURL(id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioURL(id: UUID) -> URL {
        sessionURL(id: id).appendingPathComponent("audio.caf")
    }

    func prepare(id: UUID) throws {
        let directory = sessionURL(id: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
    }

    func save(_ meeting: ArchivedMeeting) {
        guard !meeting.lines.isEmpty else { return }
        do {
            try prepare(id: meeting.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(meeting)
            let url = sessionURL(id: meeting.id).appendingPathComponent("transcript.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            DeveloperConsole.shared.log(.info, category: "MeetingArchive", "saved lines=\(meeting.lines.count)")
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingArchive", "save failed code=\((error as NSError).code)")
        }
    }

    func loadAll() -> [ArchivedMeeting] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
                  let meeting = try? decoder.decode(ArchivedMeeting.self, from: data) else {
                return nil
            }
            return meeting
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func audioFileURL(id: UUID) -> URL? {
        let url = audioURL(id: id)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func delete(id: UUID) {
        try? fileManager.removeItem(at: sessionURL(id: id))
    }

    // MARK: - 내보내기 텍스트(순수 함수, 단위 테스트 대상)

    nonisolated static func exportText(_ meeting: ArchivedMeeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var output = "TurboMeta 회의 녹취록\n"
        output += "시작: \(formatter.string(from: meeting.startedAt))\n"
        if let endedAt = meeting.endedAt {
            output += "종료: \(formatter.string(from: endedAt))\n"
        }
        output += "발화 \(meeting.lines.count)건\n"

        for line in meeting.lines {
            output += "\n[\(offsetText(line.offset))] \(line.text)\n"
            if let whisper = line.whisper, !whisper.isEmpty {
                let term = line.term.map { "\($0) — " } ?? ""
                output += "  └ 귓속말: \(term)\(whisper)\n"
            }
        }
        return output
    }

    nonisolated static func offsetText(_ offset: TimeInterval) -> String {
        let total = Int(max(0, offset))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

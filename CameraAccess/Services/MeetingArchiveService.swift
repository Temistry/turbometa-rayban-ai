/*
 * 회의 녹취록 보관 서비스
 *
 * 세션마다 폴더를 만들어 음성 원본(audio.caf)과 전사 텍스트(transcript.json)를
 * 함께 보관한다. 파일은 앱 전용 문서 폴더에 파일 보호(.complete)로 저장하며
 * 외부 반출은 사용자가 공유 버튼으로 직접 선택할 때만 일어난다.
 */

import Foundation
import AVFoundation
import SQLite3

enum ConversationMode: String, Codable, CaseIterable, Identifiable {
    case realtime
    case passive
    var id: String { rawValue }
    var title: String { self == .realtime ? "실시간" : "패시브" }
    var permitsLiveAI: Bool { self == .realtime }
    var permitsCamera: Bool { self == .realtime }
}

enum ConversationProcessingState: String, Codable {
    case unprocessed, processing, completed, failed

    var title: String {
        switch self {
        case .unprocessed: return "미처리 녹음"
        case .processing: return "처리 중"
        case .completed: return "처리 완료"
        case .failed: return "처리 중단 · 재시도 가능"
        }
    }
}

/// One transactional database per recording; audio files remain beside it.
/// Independent rows let live checkpoints retain segments no longer on screen.
private final class MeetingArchiveDatabase {
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            sqlite3_busy_timeout(handle, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func containsSession() throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT 1 FROM records WHERE kind='session' LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw CocoaError(.fileReadCorruptFile) }
        return result == SQLITE_ROW
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func put<T: Encodable>(_ value: T, kind: String, id: String) throws {
        let data = try encoder.encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO records(kind,id,payload) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }

    func write(_ meeting: ArchivedMeeting, merge: Bool) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if !merge { try execute("DELETE FROM records WHERE kind IN ('line','catch','speaker')") }
            var metadata = meeting
            metadata.lines = []
            metadata.catches = meeting.catches == nil ? nil : []
            metadata.audioChunks = meeting.audioChunks == nil ? nil : []
            metadata.speakerTurns = meeting.speakerTurns == nil ? nil : []
            try put(metadata, kind: "session", id: meeting.id.uuidString)
            for line in meeting.lines { try put(line, kind: "line", id: line.id.uuidString) }
            for item in meeting.catches ?? [] { try put(item, kind: "catch", id: item.id.uuidString) }
            for chunk in meeting.audioChunks ?? [] { try put(chunk, kind: "audio", id: chunk.filename) }
            for turn in meeting.speakerTurns ?? [] { try put(turn, kind: "speaker", id: turn.id.uuidString) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func read() throws -> ArchivedMeeting? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT kind,payload FROM records", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        var meeting: ArchivedMeeting?
        var lines: [ArchivedMeetingLine] = []
        var catches: [ArchivedMeetingCatch] = []
        var chunks: [ArchivedAudioChunk] = []
        var speakers: [ArchivedSpeakerTurn] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let kind = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            switch String(cString: kind) {
            case "session": meeting = try decoder.decode(ArchivedMeeting.self, from: data)
            case "line": lines.append(try decoder.decode(ArchivedMeetingLine.self, from: data))
            case "catch": catches.append(try decoder.decode(ArchivedMeetingCatch.self, from: data))
            case "audio": chunks.append(try decoder.decode(ArchivedAudioChunk.self, from: data))
            case "speaker": speakers.append(try decoder.decode(ArchivedSpeakerTurn.self, from: data))
            default: break
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadCorruptFile) }
        meeting?.lines = lines.sorted { $0.offset < $1.offset }
        if !catches.isEmpty || meeting?.catches != nil {
            meeting?.catches = catches.sorted { $0.offset < $1.offset }
        }
        if !chunks.isEmpty || meeting?.audioChunks != nil {
            meeting?.audioChunks = chunks.sorted { $0.offset < $1.offset }
        }
        if !speakers.isEmpty || meeting?.speakerTurns != nil {
            meeting?.speakerTurns = speakers.sorted { $0.offset < $1.offset }
        }
        return meeting
    }
}

struct ArchivedMeetingLine: Codable, Identifiable, Equatable {
    var id = UUID()
    /// 세션 시작 대비 초 단위 오프셋.
    let offset: TimeInterval
    let text: String
    var term: String?
    var whisper: String?
    var category: String?
    var speaker: String? = nil
    var role: String? = nil
    var sourceURLs: [String]? = nil
}

struct ArchivedAudioChunk: Codable, Equatable, Identifiable {
    var id: String { filename }
    let filename: String
    let offset: TimeInterval
    let duration: TimeInterval
}

struct ArchivedRouteEvent: Codable, Equatable {
    let offset: TimeInterval
    let message: String
}

struct ArchivedSpeakerTurn: Codable, Equatable, Identifiable {
    var id = UUID()
    let offset: TimeInterval
    let text: String
    /// Speaker labels are scoped to each API chunk, not global person identities.
    let speaker: String
    let role: String
}

/// 보관된 잡아낸 항목. kind는 CatchKind.rawValue 문자열로 보관한다.
struct ArchivedMeetingCatch: Codable, Identifiable, Equatable {
    var id = UUID()
    let kind: String
    let quote: String
    let point: String
    let ask: String
    let confidence: Double
    /// 세션 시작 대비 초 단위 오프셋.
    let offset: TimeInterval
    let speakerKnown: Bool
}

struct ArchivedMeeting: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var lines: [ArchivedMeetingLine]
    /// 이전 버전 파일과 호환을 위해 선택값으로 둔다.
    var catches: [ArchivedMeetingCatch]?
    var mode: ConversationMode? = nil
    var processingState: ConversationProcessingState? = nil
    var transcribedUnits: [String]? = nil
    var analyzedLines: [UUID]? = nil
    var audioChunks: [ArchivedAudioChunk]? = nil
    var recovered: Bool? = nil
    var routeEvents: [ArchivedRouteEvent]? = nil
    var speakerTurns: [ArchivedSpeakerTurn]? = nil
}

@MainActor
final class MeetingArchiveService: ObservableObject {
    static var recordingID: UUID?
    private static var processingIDs = Set<UUID>()
    static var isProcessing: Bool { !processingIDs.isEmpty }
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
        // 회의는 화면이 잠긴 뒤에도 이어지고 끝난다. complete 등급은 잠금 중 쓰기가 막혀
        // 전사 저장이 code=513으로 실패하고 녹음(audio.caf)도 끊긴다.
        // 대화 저장소와 같은 프로젝트 기준(첫 잠금 해제 이후 접근)을 쓴다. 새 파일은 폴더 등급을 따른다.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
    }

    @discardableResult
    func save(_ meeting: ArchivedMeeting) -> Bool {
        guard !meeting.lines.isEmpty || meeting.mode != nil else { return true }
        do {
            try store(meeting, merge: false)
            return true
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingArchive", "save failed code=\((error as NSError).code)")
            return false
        }
    }

    private func store(_ meeting: ArchivedMeeting, merge: Bool) throws {
        try prepare(id: meeting.id)
        let url = sessionURL(id: meeting.id).appendingPathComponent("archive.sqlite")
        let database = try MeetingArchiveDatabase(url: url)
        if try !database.containsSession(), let legacy = legacyMeeting(folder: sessionURL(id: meeting.id)) {
            try database.write(legacy, merge: false)
        }
        try database.write(meeting, merge: merge)
    }

    /// Upsert visible revisions without deleting earlier, off-screen transcript segments.
    @discardableResult
    func checkpoint(_ meeting: ArchivedMeeting) -> Bool {
        do {
            try store(meeting, merge: true)
            return true
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingArchive", "checkpoint failed code=\((error as NSError).code)")
            return false
        }
    }

    private func legacyMeeting(folder: URL) -> ArchivedMeeting? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")) else { return nil }
        return try? decoder.decode(ArchivedMeeting.self, from: data)
    }

    func loadAll() -> [ArchivedMeeting] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ) else { return [] }

        return folders.compactMap { folder in
            let databaseURL = folder.appendingPathComponent("archive.sqlite")
            if fileManager.fileExists(atPath: databaseURL.path) {
                do {
                    return try MeetingArchiveDatabase(url: databaseURL).read() ?? legacyMeeting(folder: folder)
                } catch { return nil }
            }
            return legacyMeeting(folder: folder)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func audioFileURL(id: UUID) -> URL? {
        audioFileURLs(id: id).first
    }

    func audioFileURLs(id: UUID) -> [URL] {
        let legacy = audioURL(id: id)
        if fileManager.fileExists(atPath: legacy.path) { return [legacy] }
        let files = (try? fileManager.contentsOfDirectory(at: sessionURL(id: id),
            includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix("audio-") && $0.pathExtension == "caf"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func isBusy(id: UUID) -> Bool {
        Self.recordingID == id || Self.processingIDs.contains(id)
    }

    /// Reconcile closed audio files locally. Never starts an external request.
    func recoverInterruptedRecordings() {
        for var meeting in loadAll() where !isBusy(id: meeting.id) {
            let chunks = audioChunks(for: meeting)
            let interrupted = meeting.endedAt == nil
            let processingInterrupted = meeting.processingState == .processing
            guard interrupted || processingInterrupted || meeting.audioChunks != chunks else { continue }
            meeting.audioChunks = chunks
            if interrupted {
                let duration = chunks.map { $0.offset + $0.duration }.max() ?? 0
                meeting.endedAt = meeting.startedAt.addingTimeInterval(duration)
                meeting.recovered = true
            }
            if processingInterrupted { meeting.processingState = .failed }
            save(meeting)
        }
    }

    func audioChunks(for meeting: ArchivedMeeting) -> [ArchivedAudioChunk] {
        var nextOffset: TimeInterval = 0
        return audioFileURLs(id: meeting.id).compactMap { url in
            guard let audio = try? AVAudioFile(forReading: url), audio.processingFormat.sampleRate > 0 else { return nil }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            let stampURL = url.appendingPathExtension("start")
            let stamp = (try? Data(contentsOf: stampURL)).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
            let offset = stamp.map { max(0, $0.timeIntervalSince(meeting.startedAt)) } ?? nextOffset
            nextOffset = offset + duration
            return ArchivedAudioChunk(filename: url.lastPathComponent, offset: offset, duration: duration)
        }
    }

    /// Called only from the user's confirmed processing action, never from loadAll().
    func process(_ original: ArchivedMeeting, progress: (ArchivedMeeting) -> Void) async throws {
        guard Self.recordingID != original.id else { throw CocoaError(.fileWriteFileExists) }
        guard Self.processingIDs.insert(original.id).inserted else { return }
        defer { Self.processingIDs.remove(original.id) }
        var meeting = loadAll().first { $0.id == original.id } ?? original
        meeting.audioChunks = audioChunks(for: meeting)
        meeting.processingState = .processing
        try store(meeting, merge: false)
        progress(meeting)
        do {
            _ = try JevClient.loadAPIKey()
            let diarizer = SpeakerDiarizationService()
            let enrollment = VoiceEnrollmentStore.load()
            let urls = audioFileURLs(id: meeting.id)
            guard !urls.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            var offset: TimeInterval = 0
            for url in urls {
                offset = meeting.audioChunks?.first { $0.filename == url.lastPathComponent }?.offset ?? offset
                let file = try AVAudioFile(forReading: url)
                let rate = file.processingFormat.sampleRate
                let chunkFrames = AVAudioFrameCount(rate * 30)
                var part = 0
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let unit = "\(url.lastPathComponent):\(part)"
                    let frame = file.framePosition
                    let count = AVAudioFrameCount(min(Int64(chunkFrames), file.length - frame))
                    if !(meeting.transcribedUnits ?? []).contains(unit) {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        try file.read(into: buffer, frameCount: count)
                        let converter = DiarizationAudioBuffer()
                        converter.append(buffer)
                        let turns = try await diarizer.diarize(chunk: converter.drain(), enrollment: enrollment)
                        meeting.speakerTurns = (meeting.speakerTurns ?? []) + turns.map { turn in
                            ArchivedSpeakerTurn(offset: offset + Double(frame) / rate + turn.start,
                                text: turn.text, speaker: "\(unit):\(turn.speaker)", role: turn.role.rawValue)
                        }
                        meeting.lines += turns.map { turn in
                            ArchivedMeetingLine(offset: offset + Double(frame) / rate + turn.start,
                                text: turn.text, speaker: "\(unit):\(turn.speaker)",
                                role: turn.role.rawValue)
                        }
                        meeting.transcribedUnits = (meeting.transcribedUnits ?? []) + [unit]
                        try store(meeting, merge: false)
                        progress(meeting)
                    } else {
                        file.framePosition = frame + Int64(count)
                    }
                    part += 1
                }
                offset += Double(file.length) / rate
            }
            let jev = JevClient()
            let gemini = MeetingGeminiService()
            for index in meeting.lines.indices {
                try Task.checkCancellation()
                let line = meeting.lines[index]
                guard !(meeting.analyzedLines ?? []).contains(line.id) else { continue }
                let earlier = Array(meeting.lines.prefix(index).suffix(8))
                let decision = try await jev.evaluate(utterance: line.text, previousUtterance: earlier.last?.text)
                if decision.needsExplanation {
                    let explanation = try await gemini.explain(utterance: line.text,
                        recentContext: earlier.map(\.text).joined(separator: " / "), sceneContext: nil)
                    meeting.lines[index].term = explanation.term
                    meeting.lines[index].whisper = explanation.text
                    meeting.lines[index].category = explanation.category
                }
                if line.role != "me" {
                    let decision = try await jev.evaluateCatch(statement: line.text,
                        earlier: earlier.map(\.text).joined(separator: " / "), speakerKnown: ["me", "other"].contains(line.role ?? ""))
                    if decision.shouldAnalyze {
                        let found = try await gemini.critique(statement: line.text,
                            earlierOther: earlier.filter { $0.role != "me" }.map(\.text),
                            mine: earlier.filter { $0.role == "me" }.map(\.text),
                            hint: decision.kind, speakerKnown: ["me", "other"].contains(line.role ?? ""))
                        if found.contains(where: { $0.kind == .claim }) {
                            let fact = try await gemini.factCheck(claim: line.text)
                            meeting.lines[index].sourceURLs = fact.links.map(\.urlString)
                        }
                        meeting.catches = (meeting.catches ?? []) + found.map { item in
                            ArchivedMeetingCatch(kind: item.kind.rawValue, quote: item.quote,
                                point: item.point, ask: item.ask, confidence: item.confidence,
                                offset: line.offset, speakerKnown: item.speakerKnown)
                        }
                    }
                }
                meeting.analyzedLines = (meeting.analyzedLines ?? []) + [line.id]
                try store(meeting, merge: false)
                progress(meeting)
            }
            meeting.processingState = .completed
            try store(meeting, merge: false)
            progress(meeting)
        } catch {
            meeting.processingState = .failed
            try? store(meeting, merge: false)
            progress(meeting)
            throw error
        }
    }

    func delete(id: UUID) {
        guard !isBusy(id: id) else { return }
        try? fileManager.removeItem(at: sessionURL(id: id))
    }

    // MARK: - 내보내기 텍스트(순수 함수, 단위 테스트 대상)

    nonisolated static func exportText(_ meeting: ArchivedMeeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var output = "TurboMeta 대화 녹취록\n"
        output += "시작: \(formatter.string(from: meeting.startedAt))\n"
        if let endedAt = meeting.endedAt {
            output += "종료: \(formatter.string(from: endedAt))\n"
        }
        output += "발화 \(meeting.lines.count)건\n"
        output += "모드: \((meeting.mode ?? .realtime).title)\n"
        for event in meeting.routeEvents ?? [] {
            output += "[\(offsetText(event.offset))] \(event.message)\n"
        }

        if let catches = meeting.catches, !catches.isEmpty {
            let counts = Dictionary(grouping: catches, by: \.kind).mapValues(\.count)
            let parts = CatchKind.allCases.compactMap { kind -> String? in
                guard let count = counts[kind.rawValue], count > 0 else { return nil }
                return "\(kind.titleKey.localized) \(count)"
            }
            output += "잡아낸 것 \(catches.count)건 (\(parts.joined(separator: " · ")))\n"
            for item in catches {
                output += "\n[\(offsetText(item.offset))] \(CatchKind(rawValue: item.kind)?.titleKey.localized ?? item.kind)\n"
                if !item.quote.isEmpty {
                    output += "  인용: \(item.quote)\n"
                }
                output += "  내용: \(item.point)\n"
                if !item.ask.isEmpty {
                    output += "  되묻기: \(item.ask)\n"
                }
            }
        }

        for line in meeting.lines {
            output += "\n[\(offsetText(line.offset))] \(line.text)\n"
            if let whisper = line.whisper, !whisper.isEmpty {
                let term = line.term.map { "\($0) — " } ?? ""
                output += "  └ 귓속말: \(term)\(whisper)\n"
            }
            for url in line.sourceURLs ?? [] { output += "  출처: \(url)\n" }
        }
        return output
    }

    nonisolated static func offsetText(_ offset: TimeInterval) -> String {
        let total = Int(max(0, offset))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

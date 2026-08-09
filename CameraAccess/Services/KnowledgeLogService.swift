/*
 * TurboMeta 지식 로그 저장 및 동기화
 *
 * 질문과 답변을 로컬 보호 저장소에 Markdown + JSONL로 남기고,
 * 사용자가 iOS 파일 선택기에서 지정한 Google Drive/Files 폴더로 복사한다.
 *
 * 보안 원칙:
 * - API Key, 인증 토큰, 긴 Base64 데이터는 기록 전에 제거한다.
 * - 사진, 음성 원본, 위치 정보는 저장하지 않는다.
 * - 질문과 답변 본문은 콘솔에 출력하지 않는다.
 * - 외부 폴더 동기화는 사용자가 직접 폴더를 지정한 경우에만 수행한다.
 */

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Knowledge event

enum KnowledgeLogSource: String, Codable {
    case quickVision = "quick_vision"
    case liveAI = "live_ai"
    case liveTranslate = "live_translate"

    var displayName: String {
        switch self {
        case .quickVision: return "퀵비전"
        case .liveAI: return "Live AI"
        case .liveTranslate: return "실시간 번역"
        }
    }
}

struct KnowledgeLogEvent: Codable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let source: KnowledgeLogSource
    let sessionID: UUID?
    let question: String
    let answer: String
    let model: String
    let language: String
    let tags: [String]
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: KnowledgeLogSource,
        sessionID: UUID? = nil,
        question: String,
        answer: String,
        model: String,
        language: String = "ko-KR",
        tags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = 1
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.sessionID = sessionID
        self.question = KnowledgeLogRedactor.redact(question)
        self.answer = KnowledgeLogRedactor.redact(answer)
        self.model = KnowledgeLogRedactor.redact(model)
        self.language = language
        self.tags = tags.map(KnowledgeLogRedactor.redact)
        self.metadata = metadata.reduce(into: [:]) { result, pair in
            result[KnowledgeLogRedactor.redact(pair.key)] = KnowledgeLogRedactor.redact(pair.value)
        }
    }
}

// MARK: - Sensitive text removal

private enum KnowledgeLogRedactor {
    private static let maximumTextLength = 20_000

    private static let rules: [(NSRegularExpression, String)] = {
        let definitions: [(String, String)] = [
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+\-/=]+"#, "$1<보안상 숨김>"),
            (#"(?i)((?:api[_ -]?key|apikey|client[_ -]?token|gateway[_ -]?token|access[_ -]?token|authorization|token|stream[_ -]?key|streamkey)\s*[:=]\s*)[\"']?[^\s,\"'&]+"#, "$1<보안상 숨김>"),
            (#"(?i)([?&](?:token|key|api_key|apikey|access_token)=)[^&\s]+"#, "$1<보안상 숨김>"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "<보안상 숨김>"),
            (#"\bAIza[0-9A-Za-z_-]{20,}\b"#, "<보안상 숨김>"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "<보안상 숨김>"),
            (#"data:(?:image|audio)/[^;\s]+;base64,[A-Za-z0-9+/=]+"#, "<대용량 데이터 생략>"),
            (#"(?<![A-Za-z0-9])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9])"#, "<대용량 데이터 생략>")
        ]

        return definitions.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ input: String) -> String {
        var output = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > maximumTextLength {
            output = String(output.prefix(maximumTextLength)) + "\n<최대 기록 길이 초과로 생략>"
        }

        for (regex, replacement) in rules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return output
    }
}

// MARK: - Protected local files

private struct KnowledgeLogSnapshot: Sendable {
    let relativePath: String
    let data: Data
}

private actor KnowledgeLogFileStore {
    private let fileManager = FileManager.default
    private let rootURL: URL
    private let logsURL: URL

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init() {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        rootURL = applicationSupport
            .appendingPathComponent("TurboMeta", isDirectory: true)
            .appendingPathComponent("KnowledgeLog", isDirectory: true)
        logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
    }

    func append(_ event: KnowledgeLogEvent) throws {
        let paths = try dailyPaths(for: event.timestamp)
        try appendJSONL(event, to: paths.jsonl)
        try appendMarkdown(event, to: paths.markdown)
    }

    func snapshots() throws -> [KnowledgeLogSnapshot] {
        guard fileManager.fileExists(atPath: logsURL.path) else { return [] }

        guard let enumerator = fileManager.enumerator(
            at: logsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var output: [KnowledgeLogSnapshot] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  ["jsonl", "md"].contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            let relative = fileURL.path.replacingOccurrences(
                of: rootURL.path + "/",
                with: ""
            )
            output.append(
                KnowledgeLogSnapshot(
                    relativePath: relative,
                    data: try Data(contentsOf: fileURL)
                )
            )
        }

        return output.sorted { $0.relativePath < $1.relativePath }
    }

    private func dailyPaths(for date: Date) throws -> (jsonl: URL, markdown: URL) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)
        let dateText = "\(year)-\(month)-\(day)"

        let directory = logsURL
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        return (
            directory.appendingPathComponent("\(dateText).jsonl"),
            directory.appendingPathComponent("\(dateText).md")
        )
    }

    private func appendJSONL(_ event: KnowledgeLogEvent, to url: URL) throws {
        var data = try jsonEncoder.encode(event)
        data.append(0x0A)
        try append(data, to: url)
    }

    private func appendMarkdown(_ event: KnowledgeLogEvent, to url: URL) throws {
        var markdown = ""
        if !fileManager.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy-MM-dd"
            markdown += "# \(formatter.string(from: event.timestamp)) TurboMeta Q&A\n\n"
            markdown += "> 자동 생성된 개인 지식 로그입니다. 사진과 음성 원본은 저장하지 않습니다.\n\n"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "ko_KR")
        timeFormatter.dateFormat = "HH:mm:ss"

        markdown += "## \(timeFormatter.string(from: event.timestamp)) · \(event.source.displayName)\n\n"
        markdown += "- 기록 ID: `\(event.id.uuidString)`\n"
        if let sessionID = event.sessionID {
            markdown += "- 세션 ID: `\(sessionID.uuidString)`\n"
        }
        markdown += "- 모델: `\(event.model)`\n"
        markdown += "- 언어: `\(event.language)`\n"
        if !event.tags.isEmpty {
            markdown += "- 태그: \(event.tags.map { "#" + markdownToken($0) }.joined(separator: " "))\n"
        }
        markdown += "\n### 질문\n\n\(event.question)\n\n"
        markdown += "### 답변\n\n\(event.answer)\n\n---\n\n"

        try append(Data(markdown.utf8), to: url)
    }

    private func markdownToken(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "#", with: "")
    }

    private func append(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try Data().write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()

        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - Public service

@MainActor
final class KnowledgeLogService: ObservableObject {
    static let shared = KnowledgeLogService()

    @Published private(set) var destinationName: String
    @Published private(set) var pendingEventCount: Int
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastErrorMessage: String?
    @Published var autoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSyncEnabled, forKey: autoSyncKey)
        }
    }

    private let fileStore = KnowledgeLogFileStore()
    private let userDefaults = UserDefaults.standard
    private let bookmarkKey = "knowledge_log_destination_bookmark"
    private let destinationNameKey = "knowledge_log_destination_name"
    private let pendingCountKey = "knowledge_log_pending_count"
    private let lastSyncKey = "knowledge_log_last_sync_date"
    private let autoSyncKey = "knowledge_log_auto_sync"
    private var scheduledSyncTask: Task<Void, Never>?

    private init() {
        destinationName = userDefaults.string(forKey: destinationNameKey) ?? ""
        pendingEventCount = max(0, userDefaults.integer(forKey: pendingCountKey))
        lastSyncDate = userDefaults.object(forKey: lastSyncKey) as? Date
        autoSyncEnabled = userDefaults.object(forKey: autoSyncKey) as? Bool ?? true
    }

    var isDestinationConfigured: Bool {
        userDefaults.data(forKey: bookmarkKey) != nil
    }

    var destinationStatusText: String {
        isDestinationConfigured && !destinationName.isEmpty
            ? destinationName
            : "설정 안 됨"
    }

    var syncStatusText: String {
        if isSyncing { return "동기화 중" }
        if pendingEventCount > 0 { return "대기 \(pendingEventCount)개" }
        if let lastSyncDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "MM-dd HH:mm"
            return "완료 \(formatter.string(from: lastSyncDate))"
        }
        return isDestinationConfigured ? "동기화 대기" : "폴더를 선택하세요"
    }

    func configureDestination(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let bookmark = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(bookmark, forKey: bookmarkKey)
            userDefaults.set(url.lastPathComponent, forKey: destinationNameKey)
            destinationName = url.lastPathComponent
            lastErrorMessage = nil
            print("[KnowledgeLog][INFO] 외부 지식 로그 폴더 설정 완료 providerFolder=selected")

            Task { await syncNow() }
        } catch {
            let nsError = error as NSError
            lastErrorMessage = "저장 폴더 권한을 보관하지 못했습니다. 폴더를 다시 선택하세요."
            print("[KnowledgeLog][ERROR] 폴더 bookmark 생성 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    func disconnectDestination() {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        userDefaults.removeObject(forKey: bookmarkKey)
        userDefaults.removeObject(forKey: destinationNameKey)
        destinationName = ""
        lastErrorMessage = nil
        print("[KnowledgeLog][INFO] 외부 지식 로그 폴더 연결 해제")
    }

    func appendQuickVision(_ record: QuickVisionRecord, model: String) {
        let event = KnowledgeLogEvent(
            id: record.id,
            timestamp: record.timestamp,
            source: .quickVision,
            question: quickVisionQuestion(for: record),
            answer: record.result,
            model: model,
            tags: ["퀵비전", record.mode.rawValue],
            metadata: ["mode": record.mode.rawValue]
        )
        append(event)
    }

    func appendConversation(_ record: ConversationRecord) {
        var pendingQuestion: ConversationMessage?

        for message in record.messages {
            switch message.role {
            case .user:
                pendingQuestion = message
            case .assistant:
                let question = pendingQuestion?.content ?? "사용자 질문의 음성 자막이 저장되지 않았습니다."
                let event = KnowledgeLogEvent(
                    timestamp: message.timestamp,
                    source: .liveAI,
                    sessionID: record.id,
                    question: question,
                    answer: message.content,
                    model: record.aiModel,
                    language: record.language,
                    tags: ["LiveAI"],
                    metadata: ["message_count": String(record.messages.count)]
                )
                append(event)
                pendingQuestion = nil
            }
        }
    }

    func appendTranslation(
        original: String,
        translated: String,
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        model: String
    ) {
        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let event = KnowledgeLogEvent(
            source: .liveTranslate,
            question: original.isEmpty ? "음성 번역" : original,
            answer: translated,
            model: model,
            language: targetLanguage.rawValue,
            tags: ["번역", sourceLanguage.rawValue, targetLanguage.rawValue],
            metadata: [
                "source_language": sourceLanguage.rawValue,
                "target_language": targetLanguage.rawValue
            ]
        )
        append(event)
    }

    func syncNow() async {
        guard !isSyncing else { return }
        guard let destinationURL = resolveDestinationURL() else {
            lastErrorMessage = "Google Drive 또는 Files 저장 폴더를 다시 선택하세요."
            return
        }

        isSyncing = true
        lastErrorMessage = nil
        defer { isSyncing = false }

        do {
            let snapshots = try await fileStore.snapshots()
            try await Task.detached(priority: .utility) {
                try Self.copy(snapshots, to: destinationURL)
            }.value

            pendingEventCount = 0
            userDefaults.set(0, forKey: pendingCountKey)
            lastSyncDate = Date()
            userDefaults.set(lastSyncDate, forKey: lastSyncKey)
            print("[KnowledgeLog][INFO] 외부 폴더 동기화 완료 files=\(snapshots.count)")
        } catch {
            let nsError = error as NSError
            lastErrorMessage = "지식 로그 동기화에 실패했습니다. 네트워크와 폴더 권한을 확인하세요."
            print("[KnowledgeLog][ERROR] 외부 폴더 동기화 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    private func append(_ event: KnowledgeLogEvent) {
        Task {
            do {
                try await fileStore.append(event)
                pendingEventCount += 1
                userDefaults.set(pendingEventCount, forKey: pendingCountKey)
                print("[KnowledgeLog][INFO] 로컬 지식 이벤트 저장 완료 source=\(event.source.rawValue) eventID=\(event.id.uuidString) content=redacted")
                scheduleAutomaticSync()
            } catch {
                let nsError = error as NSError
                lastErrorMessage = "지식 로그를 로컬에 저장하지 못했습니다."
                print("[KnowledgeLog][ERROR] 로컬 지식 이벤트 저장 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            }
        }
    }

    private func scheduleAutomaticSync() {
        guard autoSyncEnabled, isDestinationConfigured else { return }
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func resolveDestinationURL() -> URL? {
        guard let bookmark = userDefaults.data(forKey: bookmarkKey) else { return nil }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            if stale {
                let refreshed = try url.bookmarkData(
                    options: [.minimalBookmark],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                userDefaults.set(refreshed, forKey: bookmarkKey)
            }
            return url
        } catch {
            return nil
        }
    }

    private func quickVisionQuestion(for record: QuickVisionRecord) -> String {
        switch record.mode {
        case .standard: return "이게 뭐야?"
        case .health: return "이 음식이나 음료는 건강한가?"
        case .blind: return "주변 환경과 위험 요소를 설명해줘."
        case .reading: return "보이는 글자를 읽어줘."
        case .translate: return "보이는 글자를 한국어로 번역해줘."
        case .encyclopedia: return "이 대상에 대해 알려줘."
        case .custom: return record.prompt
        }
    }

    private nonisolated static func copy(
        _ snapshots: [KnowledgeLogSnapshot],
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let accessed = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { destinationURL.stopAccessingSecurityScopedResource() }
        }

        let root = destinationURL.appendingPathComponent("TurboMetaKnowledge", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        for snapshot in snapshots {
            let targetURL = root.appendingPathComponent(snapshot.relativePath, isDirectory: false)
            let parentURL = targetURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var writeError: Error?
            let options: NSFileCoordinator.WritingOptions = fileManager.fileExists(atPath: targetURL.path)
                ? .forReplacing
                : []

            coordinator.coordinate(
                writingItemAt: targetURL,
                options: options,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try snapshot.data.write(to: coordinatedURL, options: .atomic)
                } catch {
                    writeError = error
                }
            }

            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }
    }
}

// MARK: - Folder picker

struct KnowledgeLogFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    var onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: (() -> Void)?

        init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel?()
        }
    }
}

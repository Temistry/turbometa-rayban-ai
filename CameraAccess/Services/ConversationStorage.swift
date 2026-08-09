/*
 * 대화 기록 저장 서비스
 *
 * 대화 원문은 개인정보가 될 수 있으므로 UserDefaults 대신 iOS 파일 보호가 적용된
 * Application Support 영역에 저장한다. 기존 UserDefaults 데이터는 한 번만 자동 이전한다.
 */

import Foundation

final class ConversationStorage {
    static let shared = ConversationStorage()

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let legacyConversationsKey = "savedConversations"
    private let maxConversations = 100
    private let storageURL: URL

    private init() {
        let baseDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        let protectedDirectory = baseDirectory.appendingPathComponent("TurboMeta", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: protectedDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch {
            let nsError = error as NSError
            print("[ConversationStorage][ERROR] 보호 저장 폴더 생성 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }

        storageURL = protectedDirectory.appendingPathComponent("conversations.json", isDirectory: false)
        migrateLegacyDataIfNeeded()
    }

    // MARK: - Save Conversation

    func saveConversation(_ record: ConversationRecord) {
        var conversations = loadAllConversations()
        conversations.insert(record, at: 0)

        if conversations.count > maxConversations {
            conversations = Array(conversations.prefix(maxConversations))
        }

        save(conversations, reason: "대화 추가")
    }

    // MARK: - Load Conversations

    func loadAllConversations() -> [ConversationRecord] {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let conversations = try JSONDecoder().decode([ConversationRecord].self, from: data)
            print("[ConversationStorage][INFO] 대화 기록 불러오기 성공 count=\(conversations.count) bytes=\(data.count)")
            return conversations
        } catch {
            let nsError = error as NSError
            print("[ConversationStorage][ERROR] 대화 기록 불러오기 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) path=\(storageURL.lastPathComponent)")
            return []
        }
    }

    func loadConversations(limit: Int = 20, offset: Int = 0) -> [ConversationRecord] {
        let allConversations = loadAllConversations()
        guard offset >= 0, limit > 0, offset < allConversations.count else {
            return []
        }

        let endIndex = min(offset + limit, allConversations.count)
        return Array(allConversations[offset..<endIndex])
    }

    // MARK: - Delete Conversation

    func deleteConversation(_ id: UUID) {
        var conversations = loadAllConversations()
        let previousCount = conversations.count
        conversations.removeAll { $0.id == id }

        guard conversations.count != previousCount else {
            print("[ConversationStorage][WARN] 삭제할 대화 기록을 찾지 못했습니다")
            return
        }

        save(conversations, reason: "대화 삭제")
    }

    func deleteAllConversations() {
        do {
            if fileManager.fileExists(atPath: storageURL.path) {
                try fileManager.removeItem(at: storageURL)
            }
            userDefaults.removeObject(forKey: legacyConversationsKey)
            print("[ConversationStorage][INFO] 모든 대화 기록 삭제 완료")
        } catch {
            let nsError = error as NSError
            print("[ConversationStorage][ERROR] 전체 대화 기록 삭제 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    // MARK: - Get Conversation

    func getConversation(by id: UUID) -> ConversationRecord? {
        loadAllConversations().first { $0.id == id }
    }

    // MARK: - Protected persistence

    private func save(_ conversations: [ConversationRecord], reason: String) {
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(
                to: storageURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            userDefaults.removeObject(forKey: legacyConversationsKey)
            print("[ConversationStorage][INFO] \(reason) 저장 성공 count=\(conversations.count) bytes=\(data.count) protection=completeUntilFirstUserAuthentication")
        } catch {
            let nsError = error as NSError
            print("[ConversationStorage][ERROR] \(reason) 저장 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }

    private func migrateLegacyDataIfNeeded() {
        guard !fileManager.fileExists(atPath: storageURL.path),
              let legacyData = userDefaults.data(forKey: legacyConversationsKey) else {
            return
        }

        do {
            let conversations = try JSONDecoder().decode([ConversationRecord].self, from: legacyData)
            let normalized = Array(conversations.prefix(maxConversations))
            let protectedData = try JSONEncoder().encode(normalized)
            try protectedData.write(
                to: storageURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            userDefaults.removeObject(forKey: legacyConversationsKey)
            print("[ConversationStorage][INFO] 기존 UserDefaults 대화 기록을 보호 파일로 이전 완료 count=\(normalized.count) bytes=\(protectedData.count)")
        } catch {
            let nsError = error as NSError
            print("[ConversationStorage][ERROR] 기존 대화 기록 이전 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
        }
    }
}

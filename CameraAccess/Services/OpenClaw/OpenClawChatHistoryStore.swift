/*
 * OpenClaw 채팅 이력
 *
 * 사용자 메시지와 최종 답변만 파일 보호가 적용된 Application Support에 저장한다.
 * 사진 원본은 저장하지 않고 첨부 여부만 보존한다.
 */

import Foundation
import UIKit

struct OpenClawChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    let text: String
    let timestamp: Date
    let hadImage: Bool
    let eventIdentity: String?
    var image: UIImage?

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        image: UIImage? = nil,
        timestamp: Date = Date(),
        hadImage: Bool? = nil,
        eventIdentity: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.hadImage = hadImage ?? (image != nil)
        self.eventIdentity = eventIdentity
        self.image = image
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, hadImage, eventIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        hadImage = try container.decodeIfPresent(Bool.self, forKey: .hadImage) ?? false
        eventIdentity = try container.decodeIfPresent(String.self, forKey: .eventIdentity)
        image = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(hadImage, forKey: .hadImage)
        try container.encodeIfPresent(eventIdentity, forKey: .eventIdentity)
    }
}

final class OpenClawChatHistoryStore {
    static let shared = OpenClawChatHistoryStore()
    static let defaultMaximumMessages = 200

    private let fileManager: FileManager
    private let storageURL: URL
    private let maximumMessages: Int

    convenience init() {
        let fileManager = FileManager.default
        let baseDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let protectedDirectory = baseDirectory.appendingPathComponent(
            "TurboMeta",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: protectedDirectory,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
        } catch {
            let nsError = error as NSError
            print(
                "[OpenClawHistory][ERROR] 보호 저장 폴더 생성 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code)"
            )
        }

        self.init(
            storageURL: protectedDirectory.appendingPathComponent(
                "openclaw-chat-history.json",
                isDirectory: false
            ),
            maximumMessages: Self.defaultMaximumMessages,
            fileManager: fileManager
        )
    }

    init(
        storageURL: URL,
        maximumMessages: Int = OpenClawChatHistoryStore.defaultMaximumMessages,
        fileManager: FileManager = .default
    ) {
        self.storageURL = storageURL
        self.maximumMessages = max(1, maximumMessages)
        self.fileManager = fileManager
    }

    func load() -> [OpenClawChatMessage] {
        guard fileManager.fileExists(atPath: storageURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: storageURL)
            let messages = try JSONDecoder().decode(
                [OpenClawChatMessage].self,
                from: data
            )
            let bounded = Array(messages.suffix(maximumMessages))
            print(
                "[OpenClawHistory][INFO] 채팅 이력 불러오기 성공 "
                + "count=\(bounded.count) bytes=\(data.count)"
            )
            return bounded
        } catch {
            let nsError = error as NSError
            print(
                "[OpenClawHistory][ERROR] 채팅 이력 불러오기 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code)"
            )
            return []
        }
    }

    @discardableResult
    func save(_ messages: [OpenClawChatMessage]) -> [OpenClawChatMessage] {
        let bounded = Array(messages.suffix(maximumMessages))

        do {
            let data = try JSONEncoder().encode(bounded)
            try data.write(
                to: storageURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
            print(
                "[OpenClawHistory][INFO] 채팅 이력 저장 성공 "
                + "count=\(bounded.count) bytes=\(data.count)"
            )
        } catch {
            let nsError = error as NSError
            print(
                "[OpenClawHistory][ERROR] 채팅 이력 저장 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code)"
            )
        }

        return bounded
    }

    func deleteAll() {
        do {
            guard fileManager.fileExists(atPath: storageURL.path) else { return }
            try fileManager.removeItem(at: storageURL)
            print("[OpenClawHistory][INFO] 채팅 이력 전체 삭제 완료")
        } catch {
            let nsError = error as NSError
            print(
                "[OpenClawHistory][ERROR] 채팅 이력 삭제 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }
}

/*
 * 대화 허점 잡기
 *
 * 화자 구분으로 뽑은 상대 발언에서 근거 없는 단정·논리 비약·앞뒤 모순·사실 주장을 찾는다.
 * 결과는 귓속말(되물을 질문), 워치 카드, iPhone 알림(폰이 잠기면 워치로 전달)으로 알린다.
 */

import Foundation
import UserNotifications

enum CatchKind: String, CaseIterable, Equatable {
    case unsupported
    case leap
    case contradiction
    case claim

    var titleKey: String { "catch.kind.\(rawValue)" }

    var symbol: String {
        switch self {
        case .unsupported: return "questionmark.bubble"
        case .leap: return "arrow.up.right.circle"
        case .contradiction: return "arrow.left.arrow.right.circle"
        case .claim: return "magnifyingglass.circle"
        }
    }
}

struct ConversationCatch: Identifiable, Equatable {
    let id: UUID
    let kind: CatchKind
    /// 상대 발언 인용.
    let quote: String
    /// 무엇이 문제인지 한 문장.
    let point: String
    /// 되물을 질문 한 문장.
    let ask: String
    let confidence: Double
    let timestamp: Date
    /// 화자 구분으로 상대 발언임을 확인했는지.
    let speakerKnown: Bool

    init(id: UUID = UUID(), kind: CatchKind, quote: String, point: String, ask: String,
         confidence: Double, timestamp: Date = Date(), speakerKnown: Bool) {
        self.id = id
        self.kind = kind
        self.quote = quote
        self.point = point
        self.ask = ask
        self.confidence = confidence
        self.timestamp = timestamp
        self.speakerKnown = speakerKnown
    }

    /// 귓속말 문장: 종류 + 되물을 질문.
    var whisperText: String {
        let question = ask.isEmpty ? point : ask
        return "\(kind.titleKey.localized). \(question)"
    }
}

enum ConversationCatchParser {
    /// {"catches":[{"kind","quote","point","ask","confidence"}]} 형태를 읽는다. 코드 울타리·앞뒤 설명은 무시한다.
    static func parse(_ raw: String, speakerKnown: Bool, now: Date = Date()) -> [ConversationCatch] {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["catches"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let kindRaw = item["kind"] as? String,
                  let kind = CatchKind(rawValue: kindRaw.lowercased()),
                  let point = (item["point"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !point.isEmpty else { return nil }
            let quote = ((item["quote"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ask = ((item["ask"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let confidence = min(max((item["confidence"] as? NSNumber)?.doubleValue ?? 0.5, 0), 1)
            return ConversationCatch(kind: kind, quote: quote, point: point, ask: ask,
                                     confidence: confidence, timestamp: now, speakerKnown: speakerKnown)
        }
        .prefix(2)
        .map { $0 }
    }
}

/// 잡아낸 항목을 iPhone 알림으로 보낸다. 폰이 잠겨 있으면 iOS가 워치로 넘겨 진동으로 알린다.
final class CatchNotifier {
    static let categoryIdentifier = "conversation.catch"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DeveloperConsole.shared.log(.info, category: "MeetingCatch", "notification permission granted=\(granted)")
            }
        }
    }

    func post(_ item: ConversationCatch) {
        let content = UNMutableNotificationContent()
        content.title = item.kind.titleKey.localized
        content.body = item.ask.isEmpty ? item.point : "\(item.point)\n\(item.ask)"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = Self.categoryIdentifier
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                DeveloperConsole.shared.log(.warning, category: "MeetingCatch", "notification failed code=\((error as NSError).code)")
            }
        }
    }
}

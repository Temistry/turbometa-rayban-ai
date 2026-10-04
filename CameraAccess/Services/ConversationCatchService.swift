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

// MARK: - 전사문 연결

/// 잡아낸 인용과 전사문을 잇는 순수 로직.
/// 화자 구분(Gemini)과 전사(Apple Speech)는 엔진이 달라 문장이 어긋날 수 있어
/// 완전 일치 대신 단어 겹침으로 연결하고, 겹친 단어에 색 밑줄을 놓는다.
enum CatchHighlighter {
    struct Mark: Equatable {
        let kind: CatchKind
        /// 강조할 단어.
        let word: String
        /// 전사문 시작점에서의 문자 오프셋.
        let lowerOffset: Int
        let upperOffset: Int
    }

    /// 구두점·조사 노이즈를 덜어낸 토큰. 한 글자짜리는 변별력이 없어 버린다.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// 인용의 단어 중 전사문에 있는 비율로 연결 여부를 정한다.
    static func isAssociated(lineText: String, quote: String, threshold: Double = 0.6) -> Bool {
        let quoteTokens = tokens(quote)
        guard quoteTokens.count >= 2 else {
            return !quote.isEmpty && lineText.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let lineTokens = Set(tokens(lineText))
        let hits = quoteTokens.filter { lineTokens.contains($0) }.count
        return Double(hits) / Double(quoteTokens.count) >= threshold
    }

    /// 전사문 안에서 강조할 단어 위치를 찾는다(대소문자·발음 구분 무시, 겹침 제거).
    static func marks(in lineText: String, quote: String, kind: CatchKind) -> [Mark] {
        let lineTokens = Set(tokens(lineText))
        let words = tokens(quote).filter { lineTokens.contains($0) }
        var marks: [Mark] = []
        var taken: [Range<Int>] = []
        for word in words {
            guard let range = lineText.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            let lower = lineText.distance(from: lineText.startIndex, to: range.lowerBound)
            let upper = lineText.distance(from: lineText.startIndex, to: range.upperBound)
            guard !taken.contains(where: { lower < $0.upperBound && upper > $0.lowerBound }) else { continue }
            taken.append(lower..<upper)
            marks.append(Mark(kind: kind, word: word, lowerOffset: lower, upperOffset: upper))
        }
        return marks.sorted { $0.lowerOffset < $1.lowerOffset }
    }
}

// MARK: - 대화 요약

/// 대화가 끝났을 때 한 번 만드는 요약 리포트(순수 로직, 단위 테스트 대상).
enum MeetingSummaryBuilder {
    struct Summary: Identifiable, Equatable {
        let id = UUID()
        let startedAt: Date
        let endedAt: Date
        let lineCount: Int
        let catches: [ConversationCatch]
        /// Gemini 예상 비용(USD).
        let cost: Double

        var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
        var counts: [CatchKind: Int] {
            Dictionary(grouping: catches, by: \.kind).mapValues(\.count)
        }
    }

    static func build(
        startedAt: Date,
        endedAt: Date,
        lineCount: Int,
        catches: [ConversationCatch],
        cost: Double
    ) -> Summary {
        Summary(
            startedAt: startedAt,
            endedAt: endedAt,
            lineCount: lineCount,
            catches: catches.sorted { $0.timestamp < $1.timestamp },
            cost: max(0, cost)
        )
    }

    /// 요약을 공용 텍스트로 내보낸다.
    nonisolated static func exportText(_ summary: Summary) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var output = "TurboMeta 대화 리포트\n"
        output += "기간: \(formatter.string(from: summary.startedAt)) ~ \(formatter.string(from: summary.endedAt))\n"
        output += "대화 시간: \(MeetingArchiveService.offsetText(summary.duration))\n"
        output += "발화 \(summary.lineCount)건 · 잡아낸 것 \(summary.catches.count)건 · 예상 비용 \(String(format: "$%.4f", summary.cost))\n"

        let counts = summary.counts
        let parts = CatchKind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(kind.titleKey.localized) \(count)"
        }
        if !parts.isEmpty {
            output += "종류: \(parts.joined(separator: " · "))\n"
        }

        for item in summary.catches {
            let offset = item.timestamp.timeIntervalSince(summary.startedAt)
            output += "\n[\(MeetingArchiveService.offsetText(max(0, offset)))] \(item.kind.titleKey.localized)\n"
            if !item.quote.isEmpty {
                output += "  인용: \(item.quote)\n"
            }
            output += "  내용: \(item.point)\n"
            if !item.ask.isEmpty {
                output += "  되묻기: \(item.ask)\n"
            }
        }
        return output
    }
}

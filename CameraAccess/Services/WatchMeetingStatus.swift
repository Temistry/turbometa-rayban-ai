import Foundation

/// 폰 앱과 워치 앱이 공유하는 회의 상태 페이로드.
/// iOS와 watchOS 두 타깃에서 모두 컴파일된다.
enum WatchMeetingStatus {
    static let state = "state"
    static let route = "route"
    static let startedAt = "startedAt"
    static let latest = "latest"
    static let recent = "recent"
    static let whisperCount = "whispers"
    static let error = "error"
    static let quotaPaused = "quotaPaused"

    static func payload(state: String, route: String, startedAt: Date?, latest: String,
                        recent: [String], whisperCount: Int, error: String,
                        quotaPaused: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            Self.state: state,
            Self.route: route,
            Self.latest: latest,
            Self.recent: recent,
            Self.whisperCount: whisperCount,
            Self.error: error,
            Self.quotaPaused: quotaPaused
        ]
        if let startedAt {
            payload[Self.startedAt] = startedAt.timeIntervalSince1970
        }
        return payload
    }
}

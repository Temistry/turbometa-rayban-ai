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
    /// 사진 설명 진행 상태: "" 없음, "working" 촬영·설명 중, "failed" 실패.
    static let scene = "scene"
    static let sceneWorking = "working"
    static let sceneFailed = "failed"
    /// 최근 30초 동안 마이크에 거의 소리가 들어오지 않음.
    static let micQuiet = "micQuiet"
    /// 잡아낸 허점(최신이 앞, 최대 5개). 각 항목은 catchEntry 형식.
    static let catches = "catches"
    static let catchID = "id"
    static let catchKind = "kind"
    static let catchTitle = "title"
    static let catchPoint = "point"
    static let catchAsk = "ask"

    static func catchEntry(id: String, kind: String, title: String, point: String, ask: String) -> [String: String] {
        [catchID: id, catchKind: kind, catchTitle: title, catchPoint: point, catchAsk: ask]
    }

    static func payload(state: String, route: String, startedAt: Date?, latest: String,
                        recent: [String], whisperCount: Int, error: String,
                        quotaPaused: Bool, scene: String = "", micQuiet: Bool = false,
                        catches: [[String: String]] = []) -> [String: Any] {
        var payload: [String: Any] = [
            Self.state: state,
            Self.route: route,
            Self.latest: latest,
            Self.recent: recent,
            Self.whisperCount: whisperCount,
            Self.error: error,
            Self.quotaPaused: quotaPaused,
            Self.scene: scene,
            Self.micQuiet: micQuiet,
            Self.catches: catches
        ]
        if let startedAt {
            payload[Self.startedAt] = startedAt.timeIntervalSince1970
        }
        return payload
    }
}

/// 워치 → 폰 촬영 요청 메시지와 응답 값. 두 타깃이 공유한다.
enum WatchCapture {
    static let actionKey = "action"
    static let captureAction = "capturePhoto"
    static let resultKey = "result"
    /// 촬영을 시작했다.
    static let accepted = "accepted"
    /// 이미 촬영·설명·귓속말 중이다.
    static let busy = "busy"
    /// 폰 앱이 요청을 처리할 수 없다(회의 화면 미준비, 오류 중지, 시작·종료 중).
    static let unavailable = "unavailable"
}

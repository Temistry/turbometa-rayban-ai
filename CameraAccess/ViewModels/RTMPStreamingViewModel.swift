/*
 * RTMP 라이브 송출 상태 관리자
 * 스트림 키는 현재 iPhone 전용 Keychain에 저장하고 로그에는 URL 경로/키를 남기지 않는다.
 */

import Combine
import Security
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "RTMPStreaming")

@MainActor
final class RTMPStreamingViewModel: ObservableObject {
    @Published var rtmpUrl = ""
    @Published var streamKey = ""
    @Published var selectedPlatform: StreamingPlatform = .custom
    @Published var bitrate = 2_000_000

    @Published var isStreaming = false
    @Published var isConnecting = false
    @Published var connectionStatus: ConnectionStatus = .disconnected

    @Published var framesSent: Int64 = 0
    @Published var currentFps = 0.0
    @Published var connectionTime: TimeInterval = 0
    @Published var bytesSent: Int64 = 0

    @Published var showError = false
    @Published var errorMessage: String?
    @Published var showSettings = false

    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected
        case streaming
        case error(String)

        var displayText: String {
            switch self {
            case .disconnected: return "rtmp.status.disconnected".localized
            case .connecting: return "rtmp.status.connecting".localized
            case .connected: return "rtmp.status.connected".localized
            case .streaming: return "rtmp.status.streaming".localized
            case .error(let message): return message
            }
        }

        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .yellow
            case .connected: return .green
            case .streaming: return .red
            case .error: return .orange
            }
        }
    }

    enum StreamingPlatform: String, CaseIterable {
        case custom
        case youtube
        case twitch
        case bilibili
        case douyin
        case tiktok
        case facebook

        var displayName: String {
            switch self {
            case .custom: return "rtmp.platform.custom".localized
            case .youtube: return "YouTube Live"
            case .twitch: return "Twitch"
            case .bilibili: return "Bilibili"
            case .douyin: return "Douyin"
            case .tiktok: return "TikTok"
            case .facebook: return "Facebook Live"
            }
        }

        var defaultRtmpUrl: String {
            switch self {
            case .custom: return ""
            case .youtube: return "rtmp://a.rtmp.youtube.com/live2"
            case .twitch: return "rtmp://live.twitch.tv/app"
            case .bilibili: return "rtmp://live-push.bilivideo.com/live-bvc"
            case .douyin: return "rtmp://push-rtmp-l6.douyincdn.com/third"
            case .tiktok: return "rtmp://push.tiktokv.com/live"
            case .facebook: return "rtmps://live-api-s.facebook.com:443/rtmp"
            }
        }

        var icon: String {
            switch self {
            case .custom: return "server.rack"
            case .youtube: return "play.rectangle.fill"
            case .twitch: return "gamecontroller.fill"
            case .bilibili: return "tv.fill"
            case .douyin: return "music.note"
            case .tiktok: return "music.note.tv.fill"
            case .facebook: return "f.circle.fill"
            }
        }
    }

    private let streamingService: RTMPStreamingService
    private weak var streamViewModel: StreamSessionViewModel?
    private var statsTimer: Timer?
    private var startTime: Date?

    private let keychainService = "com.smartview.glassai.rtmp"
    private let keychainAccount = "stream_key"

    init() {
        streamingService = RTMPStreamingService()
        setupServiceCallbacks()
        loadSavedSettings()
        hardenStoredStreamKey()
        logger.info("RTMP 상태 관리자 초기화")
    }

    deinit {
        statsTimer?.invalidate()
        streamingService.stopStreaming()
    }

    var isEncryptedTransport: Bool {
        rtmpUrl.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("rtmps://")
    }

    var transportSecurityText: String {
        if rtmpUrl.isEmpty {
            return "송출 주소를 입력하세요"
        }
        return isEncryptedTransport
            ? "RTMPS 암호화 연결"
            : "RTMP 평문 연결: 신뢰할 수 있는 네트워크에서만 사용하세요"
    }

    func setStreamViewModel(_ viewModel: StreamSessionViewModel) {
        streamViewModel = viewModel
    }

    func selectPlatform(_ platform: StreamingPlatform) {
        selectedPlatform = platform
        if platform != .custom {
            rtmpUrl = platform.defaultRtmpUrl
        }
        logger.info("플랫폼 선택 platform=\(platform.rawValue, privacy: .public) encrypted=\(self.isEncryptedTransport, privacy: .public)")
    }

    func startStreaming() {
        guard !isStreaming else {
            logger.warning("이미 송출 중이므로 시작 요청 무시")
            return
        }

        guard let validated = validatedDestination() else { return }
        logger.info("RTMP 송출 시작 host=\(validated.host, privacy: .public) scheme=\(validated.scheme, privacy: .public) bitrate=\(self.bitrate, privacy: .public) keyConfigured=\(!self.streamKey.isEmpty, privacy: .public)")

        isConnecting = true
        connectionStatus = .connecting
        streamingService.startStreaming(
            url: validated.fullURL,
            width: 504,
            height: 504,
            bitrate: bitrate
        )
        saveSettings()
    }

    func stopStreaming() {
        logger.info("RTMP 송출 중지")
        streamingService.stopStreaming()

        isStreaming = false
        isConnecting = false
        connectionStatus = .disconnected
        statsTimer?.invalidate()
        statsTimer = nil
        framesSent = 0
        currentFps = 0
        connectionTime = 0
        bytesSent = 0
    }

    func feedFrame(_ image: UIImage, timestamp: Int64) {
        guard isStreaming else { return }
        streamingService.feedFrame(image, timestamp: timestamp)
    }

    func dismissError() {
        showError = false
        errorMessage = nil
    }

    private func setupServiceCallbacks() {
        streamingService.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }

        streamingService.onStatsUpdated = { [weak self] stats in
            Task { @MainActor in
                self?.framesSent = stats.framesSent
                self?.currentFps = stats.fps
                self?.connectionTime = stats.connectionTime
                self?.bytesSent = stats.bytesSent
            }
        }

        streamingService.onError = { [weak self] error in
            Task { @MainActor in
                self?.presentError(error)
            }
        }
    }

    private func handleStateChange(_ state: RTMPStreamingState) {
        switch state {
        case .idle:
            connectionStatus = .disconnected
            isStreaming = false
            isConnecting = false
        case .connecting:
            connectionStatus = .connecting
            isConnecting = true
            isStreaming = false
        case .streaming:
            connectionStatus = .streaming
            isStreaming = true
            isConnecting = false
            startTime = Date()
            startStatsTimer()
        case .disconnected:
            connectionStatus = .disconnected
            isStreaming = false
            isConnecting = false
            statsTimer?.invalidate()
        case .error(let message):
            connectionStatus = .error(message)
            isStreaming = false
            isConnecting = false
            presentError(message)
        }
    }

    private func validatedDestination() -> (fullURL: String, scheme: String, host: String)? {
        let base = rtmpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !base.isEmpty,
              let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              scheme == "rtmp" || scheme == "rtmps" else {
            presentError("rtmp.error.invalidurl".localized)
            return nil
        }

        guard components.user == nil, components.password == nil else {
            presentError("송출 주소에 사용자 이름이나 비밀번호를 넣지 마세요. 스트림 키 입력란을 사용하세요")
            return nil
        }

        var fullURL = base
        if !key.isEmpty {
            if !fullURL.hasSuffix("/") { fullURL += "/" }
            fullURL += key
        }

        return (fullURL, scheme, host)
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startTime = self.startTime else { return }
                self.connectionTime = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
        logger.error("RTMP 오류 description=\(message, privacy: .public)")
    }

    private func saveSettings() {
        UserDefaults.standard.set(rtmpUrl, forKey: "rtmp_url")
        UserDefaults.standard.set(selectedPlatform.rawValue, forKey: "rtmp_platform")
        UserDefaults.standard.set(bitrate, forKey: "rtmp_bitrate")
        saveStreamKeyToKeychain(streamKey)
    }

    private func loadSavedSettings() {
        rtmpUrl = UserDefaults.standard.string(forKey: "rtmp_url") ?? ""
        streamKey = loadStreamKeyFromKeychain() ?? ""

        if let savedPlatform = UserDefaults.standard.string(forKey: "rtmp_platform"),
           let platform = StreamingPlatform(rawValue: savedPlatform) {
            selectedPlatform = platform
        }

        let savedBitrate = UserDefaults.standard.integer(forKey: "rtmp_bitrate")
        if savedBitrate > 0 { bitrate = savedBitrate }

        if let legacyKey = UserDefaults.standard.string(forKey: "rtmp_stream_key"), !legacyKey.isEmpty {
            saveStreamKeyToKeychain(legacyKey)
            if streamKey.isEmpty { streamKey = legacyKey }
            UserDefaults.standard.removeObject(forKey: "rtmp_stream_key")
            logger.info("이전 RTMP 스트림 키를 Keychain으로 이전")
        }
    }

    private func saveStreamKeyToKeychain(_ key: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("RTMP 스트림 키 저장 실패 status=\(status, privacy: .public)")
        }
    }

    private func loadStreamKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func hardenStoredStreamKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("기존 RTMP 스트림 키 접근 정책 강화 실패 status=\(status, privacy: .public)")
        }
    }
}

/*
 * OpenClaw Node Service
 *
 * Ray-Ban Meta를 OpenClaw의 카메라 노드로 연결한다.
 * 자격 증명은 기기 전용 Keychain에 저장하고, 로그에는 메시지 본문과 토큰을 남기지 않는다.
 */

import Foundation
import Security
import UIKit

// MARK: - Connection state

enum OpenClawConnectionState: Equatable {
    case disconnected
    case connecting
    case waitingForPairing
    case connected
    case error(String)

    static func == (lhs: OpenClawConnectionState, rhs: OpenClawConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.waitingForPairing, .waitingForPairing),
             (.connected, .connected):
            return true
        case (.error(let first), .error(let second)):
            return first == second
        default:
            return false
        }
    }
}

enum OpenClawTransportMode: String, CaseIterable {
    case standard
    case meshnet
}

enum OpenClawGatewayTokenAvailability: Equatable {
    case unknown
    case configured
    case notConfigured
    case temporarilyUnavailable
    case failed

    var canStartConnection: Bool {
        self == .configured
    }
}

private enum OpenClawGatewayTokenReadResult {
    case available(String)
    case notFound
    case temporarilyUnavailable
    case failed(OSStatus)
}

enum OpenClawImageAttachmentPreparer {
    static let maximumJPEGBytes = 4 * 1024 * 1024

    /// Preserves an already-valid JPEG byte-for-byte. Oversized device JPEGs are decoded only for
    /// an analysis attachment and re-encoded at the highest full-resolution quality that fits;
    /// protected originals remain untouched.
    static func prepareJPEGData(_ originalData: Data) -> Data? {
        guard !originalData.isEmpty else { return nil }
        if originalData.count <= maximumJPEGBytes {
            return originalData
        }
        guard let image = UIImage(data: originalData) else { return nil }
        return encodeWithinBudget(image)
    }

    static func prepareJPEGDataOffMain(_ originalData: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            prepareJPEGData(originalData)
        }.value
    }

    private static func encodeWithinBudget(_ image: UIImage) -> Data? {
        let qualities: [CGFloat] = stride(
            from: CGFloat(1.0),
            through: CGFloat(0.3),
            by: -0.05
        ).map { $0 }
        var currentImage = image

        for scaleStep in 0...12 {
            for quality in qualities {
                if let data = currentImage.jpegData(compressionQuality: quality),
                   data.count <= maximumJPEGBytes {
                    return data
                }
            }

            guard scaleStep < 12 else { break }
            let newSize = CGSize(
                width: floor(currentImage.size.width * 0.9),
                height: floor(currentImage.size.height * 0.9)
            )
            guard newSize.width >= 200, newSize.height >= 200 else { break }
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            currentImage = renderer.image { _ in
                currentImage.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return nil
    }
}

enum OpenClawConversationError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case connectionFailed
    case requestInProgress
    case responseTimeout
    case disconnected
    case invalidImage
    case gatewayRejected(String)
    case deliveryAmbiguous

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "OpenClaw Gateway 설정이 필요합니다."
        case .connectionFailed: return "OpenClaw Gateway에 연결하지 못했습니다."
        case .requestInProgress: return "이전 OpenClaw 요청을 처리하고 있습니다."
        case .responseTimeout: return "OpenClaw 답변 대기 시간이 초과되었습니다."
        case .disconnected: return "OpenClaw 연결이 끊어졌습니다."
        case .invalidImage: return "OpenClaw에 보낼 이미지를 준비하지 못했습니다."
        case .gatewayRejected: return "OpenClaw Gateway가 요청을 거부했습니다."
        case .deliveryAmbiguous: return "요청 전달 여부를 확인할 수 없습니다. 자동으로 다시 보내지 않습니다."
        }
    }
}

enum OpenClawConversationOwner: String, Equatable, Sendable {
    case chat
    case galvis
    case quickShot
}

struct OpenClawConversationReceipt: Equatable, Sendable {
    let requestID: UUID
    let idempotencyKey: UUID
    let userMessageID: UUID
}

struct OpenClawConversationResult: Equatable, Sendable {
    let receipt: OpenClawConversationReceipt
    let assistantMessageID: UUID
    let responseText: String
}

enum OpenClawFinalSpeechPolicy {
    static func shouldAutoSpeak(owner: OpenClawConversationOwner?) -> Bool {
        owner != .galvis
    }
}

enum OpenClawConversationDeliveryPhase: Equatable, Sendable {
    case notStarted
    case writeStarted
    case writeCompleted
    case gatewayAcknowledged

    var timeoutError: OpenClawConversationError {
        switch self {
        case .notStarted:
            return .responseTimeout
        case .writeStarted, .writeCompleted:
            return .deliveryAmbiguous
        case .gatewayAcknowledged:
            return .responseTimeout
        }
    }

    var disconnectError: OpenClawConversationError {
        switch self {
        case .notStarted:
            return .disconnected
        case .writeStarted, .writeCompleted:
            return .deliveryAmbiguous
        case .gatewayAcknowledged:
            return .responseTimeout
        }
    }
}

enum OpenClawDisconnectPolicy {
    static func shouldHandle(
        callbackGeneration: Int,
        currentGeneration: Int,
        handledGeneration: Int?,
        isDisconnected: Bool
    ) -> Bool {
        callbackGeneration == currentGeneration
            && handledGeneration != callbackGeneration
            && !isDisconnected
    }
}

/// Governs when the reconnect backoff counter is allowed to reset after a successful
/// handshake. A connection is only considered "stable" — and therefore safe to reset
/// `reconnectAttempts` for — once it has stayed on the *same* connection generation and in
/// the *connected* state for the full `stableConnectionWindow`. Any reconnect or explicit
/// disconnect in that window bumps the generation, which this policy treats as disqualifying:
/// resetting the counter for a connection that already churned would let a flapping gateway
/// make the client hammer it at full speed forever instead of backing off.
enum OpenClawStableConnectionPolicy {
    static func shouldResetReconnectAttempts(
        timerGeneration: Int,
        currentGeneration: Int,
        isConnected: Bool
    ) -> Bool {
        timerGeneration == currentGeneration && isConnected
    }
}

enum OpenClawConnectionAttemptPolicy {
    static func canAutomaticAttempt(
        hasPendingReconnect: Bool,
        isAttemptInFlight: Bool,
        isConnectedOrConnecting: Bool,
        isApplicationActive: Bool,
        tokenAvailability: OpenClawGatewayTokenAvailability
    ) -> Bool {
        !hasPendingReconnect
            && !isAttemptInFlight
            && !isConnectedOrConnecting
            && isApplicationActive
            && tokenAvailability.canStartConnection
    }

    static func shouldConnectOnForeground(
        hasPendingReconnect: Bool,
        pendingForegroundReconnect: Bool,
        isEnabledAndDisconnected: Bool
    ) -> Bool {
        !hasPendingReconnect
            && (pendingForegroundReconnect || isEnabledAndDisconnected)
    }
}

enum OpenClawSpeechResponseFormatter {
    static let maximumLength = 1_200

    static func shouldSpeak(
        state: String,
        isEnabled: Bool,
        text: String,
        lastSpokenText: String?
    ) -> Bool {
        state == "final" && isEnabled && !text.isEmpty && text != lastSpokenText
    }

    static func textForSpeech(_ text: String) -> String? {
        var result = text

        result = replacing(pattern: "```[\\s\\S]*?```", in: result, with: " ")
        result = replacing(pattern: "`([^`]+)`", in: result, with: "$1")
        result = replacing(pattern: "!\\[([^\\]]*)\\]\\([^)]*\\)", in: result, with: "$1")
        result = replacing(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)", in: result, with: "$1")
        result = replacing(pattern: "https?://\\S+", in: result, with: " ")
        result = replacing(pattern: "(?m)^\\s{0,3}#{1,6}\\s*", in: result, with: "")
        result = replacing(pattern: "(?m)^\\s*[-*+]\\s+", in: result, with: "")
        result = replacing(pattern: "(?m)^\\s*\\d+[.)]\\s+", in: result, with: "")
        result = replacing(pattern: "[*_~>|]", in: result, with: "")
        result = replacing(pattern: "\\s+", in: result, with: " ")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else { return nil }
        guard result.count > maximumLength else { return result }

        let limit = result.index(result.startIndex, offsetBy: maximumLength)
        let prefix = String(result[..<limit])
        if let sentenceEnd = prefix.lastIndex(where: { ".?!。？！".contains($0) }) {
            return String(prefix[...sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: replacement
        )
    }
}

// MARK: - Service

final class OpenClawNodeService: NSObject, ObservableObject {
    static let shared = OpenClawNodeService()

    @Published var connectionState: OpenClawConnectionState = .disconnected
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "openclaw_enabled")
    @Published var gatewayHost = UserDefaults.standard.string(forKey: "openclaw_host") ?? "127.0.0.1"
    @Published var gatewayPort = UserDefaults.standard.integer(forKey: "openclaw_port").nonZeroOrDefault(18789)
    @Published var transportMode = OpenClawTransportMode(
        rawValue: UserDefaults.standard.string(forKey: "openclaw_transport_mode") ?? ""
    ) ?? .standard
    @Published private(set) var chatMessages: [OpenClawChatMessage] = []
    @Published private(set) var pendingChatResponse = ""
    @Published private(set) var gatewayTokenAvailability: OpenClawGatewayTokenAvailability = .unknown

    private var webSocketTransport: OpenClawWebSocketTransport?
    private var connectionGeneration = 0
    private var handledDisconnectGeneration: Int?
    private var commandRouter: OpenClawCommandRouter?
    private var reconnectTask: Task<Void, Never>?
    private var stableConnectionTask: Task<Void, Never>?
    private var nodeId: String
    private var pendingNonce: String?
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private var gatewayTokenCache: String?
    private var pendingForegroundReconnect = false
    private var isApplicationActive = false
    private var applicationObserverTokens: [NSObjectProtocol] = []
    private var lastTokenReadFailureStatus: OSStatus?
    private var lastTokenHardeningFailureStatus: OSStatus?
    /// Synchronous re-entrancy guard for `connect()`. `connectionState` is only ever updated via
    /// `DispatchQueue.main.async`, so two calls to `connect()` made back-to-back on the same run
    /// loop turn (e.g. two SwiftUI `onAppear`s firing together) could both observe the stale
    /// pre-connect state and each start their own `startConnection()`, bumping
    /// `connectionGeneration` twice and opening duplicate transports. This flag is set/cleared
    /// synchronously so `connect()` stays idempotent regardless of caller timing.
    private var isConnectionAttemptInFlight = false
    private struct PendingConversation {
        let owner: OpenClawConversationOwner
        let receipt: OpenClawConversationReceipt
        let gatewayRequestID: String
        let continuation: CheckedContinuation<OpenClawConversationResult, any Error>
        var deliveryPhase: OpenClawConversationDeliveryPhase
    }

    private var handledFinalEventIdentities = Set<String>()
    private var pendingConversation: PendingConversation?
    private var pendingConversationTimeoutTask: Task<Void, Never>?
    private let chatHistoryStore: OpenClawChatHistoryStore
    private lazy var deviceIdentity = OpenClawDeviceIdentityStore.loadOrCreate()

    private let keychainService = "com.smartview.glassai.openclaw"
    private let keychainAccount = "gateway_token"

    static let minimumProtocolVersion = 3
    static let maximumProtocolVersion = 4
    private static let maxReconnectAttempts = 5
    private static let stableConnectionWindow: TimeInterval = 10
    private static let maximumWebSocketMessageSize = 8 * 1024 * 1024

    private static let commands = [
        "camera.snap",
        "camera.list",
        "device.status",
        "device.info"
    ]

    private static let caps = ["camera"]

    private override init() {
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let historyStore = OpenClawChatHistoryStore.shared
        let storedMessages = historyStore.load()
        self.nodeId = "rayban-\(deviceID.prefix(8))".lowercased()
        self.chatHistoryStore = historyStore
        self.chatMessages = storedMessages
        self.handledFinalEventIdentities = Set(
            storedMessages.compactMap(\.eventIdentity)
        )
        super.init()
        installApplicationObservers()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isApplicationActive = UIApplication.shared.applicationState == .active
            guard self.isApplicationActive else { return }
            self.refreshGatewayTokenAvailability()
            self.hardenStoredToken()
        }
    }

    deinit {
        applicationObserverTokens.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    // MARK: - Public API

    func setCommandRouter(_ router: OpenClawCommandRouter) {
        commandRouter = router
    }

    func updateTransportMode(_ mode: OpenClawTransportMode) {
        transportMode = mode
        saveSettings()
    }

    func connect() {
        beginConnection(resetBackoff: true, reason: "user")
    }

    private func beginConnection(resetBackoff: Bool, reason: String) {
        isEnabled = true
        shouldReconnect = true
        saveSettings()

        if resetBackoff {
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        guard prepareConnectionAttempt(reason: reason) else { return }
        startConnection()
    }

    /// Idempotent connection entry point for automatic callers. A pending reconnect owns the
    /// backoff window, so screens appearing during that window must not start an early transport
    /// or reset the attempt counter.
    @discardableResult
    func ensureConnected(reason: String) -> Bool {
        isEnabled = true
        shouldReconnect = true
        saveSettings()

        guard reconnectTask == nil else {
            print("[OpenClaw][INFO] ensureConnected 재연결 대기 유지 reason=\(reason) attempts=\(reconnectAttempts)")
            return false
        }
        guard prepareConnectionAttempt(reason: reason) else { return false }
        print("[OpenClaw][INFO] ensureConnected 연결 시작 reason=\(reason)")
        startConnection()
        return true
    }

    private func prepareConnectionAttempt(reason: String) -> Bool {
        let isConnectedOrConnecting = connectionState == .connected || connectionState == .connecting
        if isConnectionAttemptInFlight || isConnectedOrConnecting {
            print("[OpenClaw][INFO] 연결 요청 무시 reason=\(reason) state=\(connectionState) inFlight=\(isConnectionAttemptInFlight)")
            return false
        }

        guard isApplicationActive else {
            pendingForegroundReconnect = shouldReconnect
            print("[OpenClaw][INFO] 앱 비활성 상태라 연결 보류 reason=\(reason)")
            return false
        }

        refreshGatewayTokenAvailability()
        guard gatewayTokenAvailability.canStartConnection else {
            if gatewayTokenAvailability == .temporarilyUnavailable {
                pendingForegroundReconnect = shouldReconnect
            }
            print("[OpenClaw][WARN] Gateway 연결 준비 조건 미충족 present=false availability=\(gatewayTokenAvailability)")
            return false
        }

        isConnectionAttemptInFlight = true
        pendingForegroundReconnect = false
        return true
    }

    var isGatewayTokenConfigured: Bool {
        gatewayTokenAvailability == .configured
    }

    func refreshGatewayTokenState() {
        refreshGatewayTokenAvailability()
    }

    func disconnect() {
        failPendingConversationForDisconnect()
        shouldReconnect = false
        isEnabled = false
        isConnectionAttemptInFlight = false
        saveSettings()

        reconnectTask?.cancel()
        reconnectTask = nil
        stableConnectionTask?.cancel()
        stableConnectionTask = nil

        webSocketTransport?.cancel(closeCode: URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
        webSocketTransport = nil
        connectionGeneration += 1
        handledDisconnectGeneration = connectionGeneration

        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
        print("[OpenClaw][INFO] 사용자가 연결을 해제함")
    }

    @discardableResult
    func sendChatMessage(
        _ text: String,
        image: UIImage? = nil
    ) async throws -> OpenClawConversationResult {
        try await sendConversation(
            text,
            image: image,
            owner: .chat
        )
    }

    @discardableResult
    func sendChatMessage(
        _ text: String,
        imageJPEGData: Data,
        previewImage: UIImage
    ) async throws -> OpenClawConversationResult {
        try await sendConversation(
            text,
            image: previewImage,
            imageJPEGData: imageJPEGData,
            owner: .chat
        )
    }

    @discardableResult
    func sendConversation(
        _ text: String,
        imageJPEGData: Data? = nil,
        owner: OpenClawConversationOwner,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        userMessageID: UUID = UUID(),
        timeout: TimeInterval = 90
    ) async throws -> OpenClawConversationResult {
        try await sendConversation(
            text,
            image: nil,
            imageJPEGData: imageJPEGData,
            owner: owner,
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            userMessageID: userMessageID,
            timeout: timeout
        )
    }

    @MainActor
    private func sendConversation(
        _ text: String,
        image: UIImage?,
        imageJPEGData: Data? = nil,
        owner: OpenClawConversationOwner,
        requestID: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        userMessageID: UUID = UUID(),
        timeout: TimeInterval = 90
    ) async throws -> OpenClawConversationResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OpenClawConversationError.connectionFailed
        }
        guard pendingConversation == nil else {
            throw OpenClawConversationError.requestInProgress
        }
        guard isGatewayTokenConfigured else {
            throw OpenClawConversationError.notConfigured
        }

        if connectionState != .connected {
            _ = ensureConnected(reason: "OpenClawNodeService.sendConversation.\(owner.rawValue)")
            guard connectionState == .connected
                    || connectionState == .connecting
                    || isConnectionAttemptInFlight
                    || reconnectTask != nil else {
                throw OpenClawConversationError.connectionFailed
            }
            try await waitUntilConnected(timeout: 20)
        }

        let attachmentData: Data?
        if let imageJPEGData {
            guard let prepared = await OpenClawImageAttachmentPreparer
                .prepareJPEGDataOffMain(imageJPEGData) else {
                throw OpenClawConversationError.invalidImage
            }
            attachmentData = prepared
        } else if let image {
            guard let compressed = compressedImageData(image) else {
                throw OpenClawConversationError.invalidImage
            }
            attachmentData = compressed
        } else {
            attachmentData = nil
        }

        let userMessage = OpenClawChatMessage(
            id: userMessageID,
            role: "user",
            text: normalized,
            image: image,
            hadImage: attachmentData != nil
        )
        let receipt = OpenClawConversationReceipt(
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            userMessageID: userMessage.id
        )
        let gatewayRequestID = requestID.uuidString
        let boundedTimeout = timeout.isFinite ? min(max(timeout, 1), 300) : 90

        var attachments: [[String: Any]] = []
        if let attachmentData {
            attachments.append([
                "type": "image",
                "mimeType": "image/jpeg",
                "content": attachmentData.base64EncodedString()
            ])
        }
        var params: [String: Any] = [
            "sessionKey": chatSessionKey,
            "message": normalized,
            "idempotencyKey": idempotencyKey.uuidString
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingConversation = PendingConversation(
                    owner: owner,
                    receipt: receipt,
                    gatewayRequestID: gatewayRequestID,
                    continuation: continuation,
                    deliveryPhase: .notStarted
                )
                pendingConversationTimeoutTask?.cancel()
                pendingConversationTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: UInt64(boundedTimeout * 1_000_000_000)
                    )
                    guard !Task.isCancelled else { return }
                    self?.finishPendingConversationForTimeout()
                }

                appendChatMessage(userMessage)
                pendingChatResponse = ""
                markPendingSocketWriteStarted(gatewayRequestID: gatewayRequestID)
                sendJSON([
                    "type": "req",
                    "id": gatewayRequestID,
                    "method": "chat.send",
                    "params": params
                ]) { [weak self] error in
                    self?.handleConversationSendCompletion(
                        gatewayRequestID: gatewayRequestID,
                        error: error
                    )
                }

                // 사용자 대화 내용은 로그에 남기지 않는다.
                print(
                    "[OpenClaw][INFO] 채팅 전송 owner=\(owner.rawValue) "
                    + "textLength=\(normalized.count) imageBytes=\(attachmentData?.count ?? 0)"
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingConversation()
            }
        }
    }

    func ask(
        _ question: String,
        timeout: TimeInterval = 90
    ) async throws -> String {
        let result = try await sendConversation(
            question,
            imageJPEGData: nil,
            owner: .galvis,
            timeout: timeout
        )
        return result.responseText
    }

    func analyzeDiagnosticReport(_ prompt: String) async throws -> String {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OpenClawConversationError.connectionFailed
        }
        print("[OpenClaw][DIAGNOSTIC] 진단 분석 요청 promptLength=\(normalized.count)")
        return try await ask(normalized, timeout: 90)
    }

    func cancelPendingConversation() {
        finishPendingConversation(with: .failure(CancellationError()))
    }

    @MainActor
    private func finishPendingConversationForTimeout() {
        guard let pendingConversation else { return }
        finishPendingConversation(
            with: .failure(
                pendingConversation.deliveryPhase.timeoutError
            )
        )
    }

    private func waitUntilConnected(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch connectionState {
            case .connected:
                return
            case .error, .waitingForPairing:
                throw OpenClawConversationError.connectionFailed
            case .disconnected, .connecting:
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw OpenClawConversationError.connectionFailed
    }

    private func markPendingSocketWriteStarted(gatewayRequestID: String) {
        guard var pendingConversation,
              pendingConversation.gatewayRequestID == gatewayRequestID else { return }
        pendingConversation.deliveryPhase = .writeStarted
        self.pendingConversation = pendingConversation
    }

    private func handleConversationSendCompletion(
        gatewayRequestID: String,
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  var pendingConversation = self.pendingConversation,
                  pendingConversation.gatewayRequestID == gatewayRequestID else {
                return
            }

            if let error {
                let nsError = error as NSError
                print(
                    "[OpenClaw][ERROR] 대화 전송 실패 owner=\(pendingConversation.owner.rawValue) "
                    + "domain=\(nsError.domain) code=\(nsError.code)"
                )
                self.finishPendingConversation(
                    with: .failure(OpenClawConversationError.deliveryAmbiguous)
                )
                return
            }

            pendingConversation.deliveryPhase = .writeCompleted
            self.pendingConversation = pendingConversation
        }
    }

    private func finishPendingConversation(
        with result: Result<OpenClawConversationResult, Error>
    ) {
        pendingConversationTimeoutTask?.cancel()
        pendingConversationTimeoutTask = nil
        guard let pendingConversation else { return }
        self.pendingConversation = nil
        pendingConversation.continuation.resume(with: result)
    }

    private func failPendingConversationForDisconnect() {
        guard let pendingConversation else { return }
        finishPendingConversation(
            with: .failure(
                pendingConversation.deliveryPhase.disconnectError
            )
        )
    }

    func addLocalChatNotice(_ text: String) {
        guard !text.isEmpty else { return }
        appendChatMessage(
            OpenClawChatMessage(role: "assistant", text: text)
        )
    }

    func clearChatHistory() {
        pendingChatResponse = ""
        chatMessages = []
        handledFinalEventIdentities = []
        chatHistoryStore.deleteAll()
    }

    private var chatSessionKey = "turbometa-chat"

    private func appendChatMessage(_ message: OpenClawChatMessage) {
        chatMessages.append(message)
        chatMessages = chatHistoryStore.save(chatMessages)
    }

    // MARK: - Gateway token

    func saveGatewayToken(_ token: String) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        gatewayTokenCache = nil
        lastTokenReadFailureStatus = nil

        guard !normalizedToken.isEmpty,
              let data = normalizedToken.data(using: .utf8) else {
            gatewayTokenAvailability = .notConfigured
            print("[OpenClaw][INFO] Gateway 토큰 삭제 완료")
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            gatewayTokenCache = normalizedToken
            gatewayTokenAvailability = .configured
            print("[OpenClaw][INFO] Gateway 토큰을 기기 전용 Keychain에 저장")
        } else {
            gatewayTokenAvailability = .failed
            print("[OpenClaw][ERROR] Gateway 토큰 저장 실패 status=\(status)")
        }
    }

    func loadGatewayToken() -> String? {
        if let gatewayTokenCache { return gatewayTokenCache }
        refreshGatewayTokenAvailability()
        return gatewayTokenCache
    }

    private func readGatewayToken() -> OpenClawGatewayTokenReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let token = String(data: data, encoding: .utf8),
           !token.isEmpty {
            return .available(token)
        }
        if status == errSecItemNotFound { return .notFound }
        if status == errSecInteractionNotAllowed { return .temporarilyUnavailable }
        return .failed(status)
    }

    private func refreshGatewayTokenAvailability() {
        guard isApplicationActive else {
            gatewayTokenCache = nil
            gatewayTokenAvailability = .unknown
            return
        }

        switch readGatewayToken() {
        case .available(let token):
            gatewayTokenCache = token
            gatewayTokenAvailability = .configured
            lastTokenReadFailureStatus = nil
        case .notFound:
            gatewayTokenCache = nil
            gatewayTokenAvailability = .notConfigured
            lastTokenReadFailureStatus = nil
        case .temporarilyUnavailable:
            gatewayTokenCache = nil
            gatewayTokenAvailability = .temporarilyUnavailable
            lastTokenReadFailureStatus = errSecInteractionNotAllowed
        case .failed(let status):
            gatewayTokenCache = nil
            gatewayTokenAvailability = .failed
            logTokenReadFailureOnce(status: status)
        }
    }

    private func logTokenReadFailureOnce(status: OSStatus) {
        guard lastTokenReadFailureStatus != status else { return }
        lastTokenReadFailureStatus = status
        print("[OpenClaw][WARN] Gateway 토큰 읽기 실패 status=\(status)")
    }

    private func hardenStoredToken() {
        guard isApplicationActive else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            lastTokenHardeningFailureStatus = nil
        } else if status != errSecInteractionNotAllowed,
                  lastTokenHardeningFailureStatus != status {
            lastTokenHardeningFailureStatus = status
            print("[OpenClaw][WARN] 기존 Gateway 토큰 접근 정책 강화 실패 status=\(status)")
        }
    }

    private func installApplicationObservers() {
        let center = NotificationCenter.default
        applicationObserverTokens.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isApplicationActive = true
                self.refreshGatewayTokenAvailability()
                self.hardenStoredToken()
                if OpenClawConnectionAttemptPolicy.shouldConnectOnForeground(
                    hasPendingReconnect: self.reconnectTask != nil,
                    pendingForegroundReconnect: self.pendingForegroundReconnect,
                    isEnabledAndDisconnected: self.isEnabled && self.connectionState == .disconnected
                ) {
                    self.pendingForegroundReconnect = false
                    self.beginConnection(
                        resetBackoff: false,
                        reason: "UIApplication.didBecomeActive"
                    )
                }
            }
        )
        applicationObserverTokens.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isApplicationActive = false
                self.gatewayTokenCache = nil
                self.gatewayTokenAvailability = .unknown
                self.pendingForegroundReconnect = self.shouldReconnect
            }
        )
    }

    // MARK: - Connection

    private func startConnection() {
        guard isApplicationActive else {
            isConnectionAttemptInFlight = false
            pendingForegroundReconnect = shouldReconnect
            print("[OpenClaw][INFO] 앱 비활성 상태라 연결 시작을 보류")
            return
        }
        guard gatewayTokenCache?.isEmpty == false else {
            isConnectionAttemptInFlight = false
            refreshGatewayTokenAvailability()
            if gatewayTokenAvailability == .temporarilyUnavailable {
                pendingForegroundReconnect = shouldReconnect
            }
            print("[OpenClaw][WARN] Gateway 연결 시작 조건 미충족 present=false availability=\(gatewayTokenAvailability)")
            return
        }

        // A fresh connection attempt invalidates any pending "reset reconnectAttempts after
        // 10s stable" timer left over from a previous, now-superseded generation.
        stableConnectionTask?.cancel()
        stableConnectionTask = nil

        let url: URL
        do {
            url = try makeGatewayURL()
        } catch {
            let message = error.localizedDescription
            isConnectionAttemptInFlight = false
            DispatchQueue.main.async {
                self.connectionState = .error(message)
            }
            shouldReconnect = false
            print("[OpenClaw][ERROR] Gateway URL 검증 실패 description=\(message) port=\(gatewayPort) mode=\(transportMode.rawValue)")
            return
        }

        DispatchQueue.main.async {
            self.connectionState = .connecting
            // Once the published state flips to .connecting, the state-based guards in
            // connect()/ensureConnected() are sufficient on their own — clear the synchronous
            // flag here (rather than immediately after calling startConnection) so no window
            // exists where a reentrant call on the same thread could see neither guard engaged.
            self.isConnectionAttemptInFlight = false
        }

        let transportKind = OpenClawWebSocketTransportSelector.kind(
            for: url,
            transportMode: transportMode
        )
        connectionGeneration += 1
        let generation = connectionGeneration
        handledDisconnectGeneration = nil

        // 토큰은 URL 쿼리에 넣지 않는다. URL은 각종 프록시와 진단 로그에 남기 쉽기 때문이다.
        print("[OpenClaw][INFO] Gateway 연결 시작 scheme=\(url.scheme ?? "-") port=\(url.port ?? gatewayPort) mode=\(transportMode.rawValue) transport=\(transportKind.rawValue) tokenConfigured=\(isGatewayTokenConfigured)")

        let transport: OpenClawWebSocketTransport
        do {
            switch transportKind {
            case .urlSession:
                transport = OpenClawURLSessionWebSocketTransport(
                    url: url,
                    maximumMessageSize: Self.maximumWebSocketMessageSize
                )
            case .meshnetNetwork:
                transport = try OpenClawMeshnetWebSocketTransport(
                    url: url,
                    maximumMessageSize: Self.maximumWebSocketMessageSize
                )
            }
        } catch {
            handleTransportFailure(error, generation: generation)
            return
        }

        transport.onOpen = { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            print("[OpenClaw][INFO] WebSocket 열림 transport=\(transportKind.rawValue)")
            self.receiveMessage(generation: generation)
        }
        transport.onClose = { [weak self] code, reason in
            guard let self, self.connectionGeneration == generation else { return }
            print("[OpenClaw][WARN] WebSocket 닫힘 code=\(code) reason=\(reason ?? "-") transport=\(transportKind.rawValue)")
            self.scheduleDisconnectHandling(generation: generation)
        }
        transport.onFailure = { [weak self] error in
            self?.handleTransportFailure(error, generation: generation)
        }

        webSocketTransport = transport
        transport.start()
    }

    private func makeGatewayURL() throws -> URL {
        try OpenClawGatewayEndpoint.makeURL(
            rawHost: gatewayHost,
            defaultPort: gatewayPort,
            transportMode: transportMode
        )
    }

    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        OpenClawGatewayEndpoint.isLocalOrPrivateHost(host)
    }

    static func isMeshnetHost(_ host: String) -> Bool {
        OpenClawGatewayEndpoint.isMeshnetHost(host)
    }

    private func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "openclaw_enabled")
        UserDefaults.standard.set(gatewayHost, forKey: "openclaw_host")
        UserDefaults.standard.set(gatewayPort, forKey: "openclaw_port")
        UserDefaults.standard.set(transportMode.rawValue, forKey: "openclaw_transport_mode")
    }

    // MARK: - WebSocket messaging

    private func receiveMessage(generation: Int) {
        guard let transport = webSocketTransport else { return }
        transport.receive { [weak self] result in
            guard let self, self.connectionGeneration == generation else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.receiveMessage(generation: generation)
                }

            case .failure(let error):
                let nsError = error as NSError
                let state = self.webSocketTransport?.state
                print("[OpenClaw][ERROR] 수신 실패 domain=\(nsError.domain) code=\(nsError.code) socketState=\(String(describing: state)) reconnect=\(self.shouldReconnect)")

                if state == .canceling || state == .completed || !self.shouldReconnect {
                    return
                }
                self.scheduleDisconnectHandling(generation: generation)
            }
        }
    }

    private func sendJSON(
        _ dictionary: [String: Any],
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let text = String(data: data, encoding: .utf8) else {
            print("[OpenClaw][ERROR] 전송 JSON 직렬화 실패")
            completion?(OpenClawConversationError.connectionFailed)
            return
        }

        guard let transport = webSocketTransport, transport.state == .running else {
            print("[OpenClaw][ERROR] WebSocket이 실행 중이 아니어서 전송 실패 state=\(String(describing: self.webSocketTransport?.state))")
            completion?(OpenClawConversationError.disconnected)
            return
        }

        let generation = connectionGeneration
        transport.send(.string(text)) { [weak self] error in
            completion?(error)
            guard let error else { return }
            let nsError = error as NSError
            print("[OpenClaw][ERROR] 전송 실패 domain=\(nsError.domain) code=\(nsError.code)")
            if self?.shouldReconnect == true {
                self?.scheduleDisconnectHandling(generation: generation)
            }
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ message: OpenClawWebSocketMessage) {
        let text: String
        let byteCount: Int

        switch message {
        case .string(let string):
            text = string
            byteCount = string.utf8.count
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
            byteCount = data.count
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[OpenClaw][ERROR] 수신 JSON 파싱 실패 bytes=\(byteCount)")
            return
        }

        let type = json["type"] as? String
        let method = json["method"] as? String
        let event = json["event"] as? String
        print("[OpenClaw][INFO] 메시지 수신 type=\(type ?? "-") method=\(method ?? "-") event=\(event ?? "-") bytes=\(byteCount)")

        if type == "event" && event == "connect.challenge" {
            if let payload = json["payload"] as? [String: Any],
               let nonce = payload["nonce"] as? String {
                handleChallenge(nonce: nonce)
            } else {
                print("[OpenClaw][ERROR] 연결 challenge에 nonce가 없음")
            }
            return
        }

        if type == "res" || type == "response" {
            let ok = json["ok"] as? Bool ?? false
            if ok,
               let payload = json["payload"] as? [String: Any],
               payload["type"] as? String == "hello-ok" {
                handleHelloOK(json: json)
            } else {
                handleResponse(json: json)
            }
            return
        }

        switch type {
        case "evt", "event":
            handleEvent(method: event ?? method, json: json)
        case "req", "request":
            handleRequest(json: json)
        case "res", "response":
            handleResponse(json: json)
        default:
            print("[OpenClaw][WARN] 지원하지 않는 메시지 type=\(type ?? "nil")")
        }
    }

    // MARK: - Handshake

    private func handleChallenge(nonce: String) {
        print("[OpenClaw][INFO] 연결 challenge 수신 nonceLength=\(nonce.count)")
        pendingNonce = nonce

        guard let token = gatewayTokenCache, !token.isEmpty else {
            print("[OpenClaw][WARN] challenge 처리 중 Gateway 자격 증명을 사용할 수 없어 연결 중단")
            pendingForegroundReconnect = shouldReconnect
            webSocketTransport?.cancel(closeCode: URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
            scheduleDisconnectHandling(generation: connectionGeneration)
            return
        }
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]
        let clientID = "openclaw-ios"
        let clientMode = "node"
        let platform = "ios"
        let signedAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)

        let signature = deviceIdentity.sign(
            clientId: clientID,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            signedAtMs: signedAtMilliseconds,
            token: token,
            nonce: nonce,
            platform: platform,
            deviceFamily: nil
        )

        let auth: [String: Any] = ["token": token]

        let connectParams: [String: Any] = [
            "minProtocol": Self.minimumProtocolVersion,
            "maxProtocol": Self.maximumProtocolVersion,
            "client": [
                "id": clientID,
                "displayName": "Ray-Ban Meta Glasses",
                "version": "2.0.0",
                "mode": clientMode,
                "platform": platform,
                "modelIdentifier": UIDevice.current.model
            ],
            "role": role,
            "scopes": scopes,
            "caps": Self.caps,
            "commands": Self.commands,
            "auth": auth,
            "device": [
                "id": deviceIdentity.deviceId,
                "publicKey": deviceIdentity.publicKeyBase64Url,
                "signature": signature,
                "signedAt": signedAtMilliseconds,
                "nonce": nonce
            ]
        ]

        sendJSON([
            "type": "req",
            "id": UUID().uuidString,
            "method": "connect",
            "params": connectParams
        ])
        print("[OpenClaw][INFO] 서명된 연결 요청 전송 tokenConfigured=true")
    }

    private func handleHelloOK(json: [String: Any]) {
        // `handleHelloOK` is only ever invoked from `handleMessage`, which `receiveMessage`
        // already gates on `connectionGeneration == generation`. So `connectionGeneration` here
        // is guaranteed to be the generation of the connection that just finished its handshake.
        let generation = connectionGeneration
        DispatchQueue.main.async {
            self.connectionState = .connected
        }
        scheduleReconnectAttemptsReset(generation: generation)
        print("[OpenClaw][INFO] Gateway 연결 성공, \(Int(Self.stableConnectionWindow))초 안정 연결 후 재연결 횟수 초기화 예정")
    }

    /// Only resets `reconnectAttempts` after the connection has stayed up for
    /// `stableConnectionWindow` seconds. A connection that flaps immediately after `hello-ok`
    /// (e.g. the gateway accepts then drops the socket) must not get its backoff counter reset,
    /// or a flapping gateway would make the client reconnect at full speed forever instead of
    /// backing off. Any reconnect/disconnect in the meantime bumps `connectionGeneration`, which
    /// invalidates this task before it can fire.
    private func scheduleReconnectAttemptsReset(generation: Int) {
        stableConnectionTask?.cancel()
        stableConnectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stableConnectionWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      OpenClawStableConnectionPolicy.shouldResetReconnectAttempts(
                          timerGeneration: generation,
                          currentGeneration: self.connectionGeneration,
                          isConnected: self.connectionState == .connected
                      ) else { return }
                self.reconnectAttempts = 0
                print("[OpenClaw][INFO] \(Int(Self.stableConnectionWindow))초 안정 연결 확인, 재연결 횟수 초기화")
            }
        }
    }

    // MARK: - Events and requests

    private func handleEvent(method: String?, json: [String: Any]) {
        guard let method else { return }

        switch method {
        case "node.invoke.request", "node.invoke":
            print("[OpenClaw][INFO] 노드 명령 수신 method=\(method)")
            handleInvokeRequest(json: json)

        case "chat":
            if let payload = json["payload"] as? [String: Any],
               let state = payload["state"] as? String,
               let message = payload["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                guard !text.isEmpty else { return }

                let runID = payload["runId"] as? String
                let sequence = Self.integerValue(payload["seq"])
                let eventIdentity = Self.finalEventIdentity(
                    runID: runID,
                    sequence: sequence
                )

                DispatchQueue.main.async {
                    if state == "final" {
                        self.handleFinalChatResponse(
                            text,
                            eventIdentity: eventIdentity
                        )
                    } else {
                        self.pendingChatResponse = text
                    }
                }
                print(
                    "[OpenClaw][INFO] 채팅 응답 전달 state=\(state) "
                    + "textLength=\(text.count) eventIdentity=\(eventIdentity != nil)"
                )
            }

        case "tick", "health":
            break

        default:
            print("[OpenClaw][INFO] 기타 이벤트 method=\(method)")
        }
    }

    @MainActor
    private func handleFinalChatResponse(
        _ text: String,
        eventIdentity: String?
    ) {
        if let eventIdentity,
           handledFinalEventIdentities.contains(eventIdentity) {
            print("[OpenClaw][INFO] 중복 최종 채팅 이벤트 무시")
            return
        }

        if let eventIdentity {
            handledFinalEventIdentities.insert(eventIdentity)
        }
        pendingChatResponse = ""
        let message = OpenClawChatMessage(
            role: "assistant",
            text: text,
            eventIdentity: eventIdentity
        )
        appendChatMessage(message)

        let conversationOwner = pendingConversation?.owner
        if let summary = GalvisSpeechResponseFormatter.speechText(from: text) {
            OpenClawNotificationService.shared.postFinalResponse(
                summary: summary,
                messageID: message.id
            )

            if OpenClawFinalSpeechPolicy.shouldAutoSpeak(
                owner: conversationOwner
            ) {
                let requestID = TTSService.shared.enqueue(summary)
                print(
                    "[OpenClaw][TTS] 최종 답변 자동 발화 "
                    + "owner=general summaryLength=\(summary.count) "
                    + "enqueued=\(requestID != nil)"
                )
            } else {
                print(
                    "[OpenClaw][TTS] 요청 호출부에 발화 소유권 위임 "
                    + "owner=galvis summaryLength=\(summary.count)"
                )
            }
        } else {
            print("[OpenClaw][TTS][WARN] 최종 답변 요약을 만들 수 없음")
        }

        if let pendingConversation {
            let result = OpenClawConversationResult(
                receipt: pendingConversation.receipt,
                assistantMessageID: message.id,
                responseText: text
            )
            finishPendingConversation(with: .success(result))
        }
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func finalEventIdentity(
        runID: String?,
        sequence: Int?
    ) -> String? {
        guard let runID, !runID.isEmpty, let sequence else { return nil }
        return "\(runID):\(sequence)"
    }

    private func handleRequest(json: [String: Any]) {
        let method = json["method"] as? String ?? ""
        let id = json["id"] as? String ?? ""

        switch method {
        case "node.invoke":
            if let params = json["params"] as? [String: Any] {
                handleInvokeFromRequest(id: id, params: params)
            }

        default:
            print("[OpenClaw][WARN] 지원하지 않는 요청 method=\(method)")
            sendJSON([
                "type": "res",
                "id": id,
                "ok": false,
                "error": ["code": "UNSUPPORTED", "message": "지원하지 않는 메서드: \(method)"]
            ])
        }
    }

    private func handleResponse(json: [String: Any]) {
        let id = json["id"] as? String ?? ""
        let ok = json["ok"] as? Bool ?? false

        if ok {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      var pendingConversation = self.pendingConversation,
                      pendingConversation.gatewayRequestID == id else {
                    return
                }
                pendingConversation.deliveryPhase = .gatewayAcknowledged
                self.pendingConversation = pendingConversation
            }
            return
        }
        let error = json["error"] as? [String: Any]
        let code = error?["code"] as? String ?? "UNKNOWN"
        let message = error?["message"] as? String ?? "설명 없음"
        print("[OpenClaw][ERROR] Gateway 응답 오류 requestID=\(id.prefix(8)) code=\(code) messageLength=\(message.count)")

        if pendingConversation?.gatewayRequestID == id {
            DispatchQueue.main.async {
                self.finishPendingConversation(
                    with: .failure(OpenClawConversationError.gatewayRejected(code))
                )
            }
        }

        if code == "NOT_PAIRED" {
            DispatchQueue.main.async {
                self.connectionState = .waitingForPairing
            }
        }
    }

    // MARK: - Command invocation

    private func handleInvokeRequest(json: [String: Any]) {
        guard let params = json["params"] as? [String: Any] else { return }
        let invokeID = params["id"] as? String ?? ""
        handleInvokeFromRequest(id: invokeID, params: params)
    }

    private func handleInvokeFromRequest(id: String, params: [String: Any]) {
        let command = params["command"] as? String ?? ""
        let commandParams = params["params"] as? [String: Any]
            ?? (params["paramsjson"] as? String).flatMap { value in
                try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
            }

        guard Self.commands.contains(command) else {
            print("[OpenClaw][WARN] 허용 목록에 없는 명령 거부 command=\(command)")
            sendInvokeResult(makeErrorResult(id: id, code: "UNSUPPORTED", message: "허용되지 않은 명령입니다"))
            return
        }

        print("[OpenClaw][INFO] 명령 실행 command=\(command) requestID=\(id.prefix(8))")
        let request = OpenClawNodeInvokeRequest(
            id: id,
            command: command,
            params: commandParams,
            timeoutMs: params["timeoutms"] as? Int ?? params["timeoutMs"] as? Int
        )

        Task { @MainActor in
            let result = await self.commandRouter?.handleCommand(request)
                ?? self.makeErrorResult(id: id, code: "NO_ROUTER", message: "명령 라우터가 준비되지 않았습니다")
            self.sendInvokeResult(result)
        }
    }

    private func sendInvokeResult(_ result: OpenClawNodeInvokeResult) {
        var payload: [String: Any] = [
            "id": result.id,
            "nodeId": nodeId,
            "ok": result.ok
        ]

        if let resultPayload = result.payload,
           let data = try? JSONEncoder().encode(resultPayload),
           let jsonString = String(data: data, encoding: .utf8) {
            payload["payloadjson"] = jsonString
        }

        if let error = result.error {
            var errorDictionary: [String: Any] = [:]
            if let code = error.code { errorDictionary["code"] = code }
            if let message = error.message { errorDictionary["message"] = message }
            payload["error"] = errorDictionary
        }

        sendJSON([
            "type": "req",
            "id": UUID().uuidString,
            "method": "node.invoke.result",
            "params": payload
        ])
    }

    private func makeErrorResult(id: String, code: String, message: String) -> OpenClawNodeInvokeResult {
        OpenClawNodeInvokeResult(
            id: id,
            nodeId: nodeId,
            ok: false,
            payload: nil,
            error: OpenClawError(code: code, message: message)
        )
    }

    // MARK: - Keepalive and reconnection

    private func handleTransportFailure(_ error: Error, generation: Int) {
        guard connectionGeneration == generation else { return }
        let nsError = error as NSError
        print("[OpenClaw][ERROR] 연결 작업 종료 domain=\(nsError.domain) code=\(nsError.code)")

        if shouldReconnect {
            DispatchQueue.main.async {
                self.connectionState = .error("Gateway 네트워크 연결 오류가 발생했습니다.")
            }
            scheduleDisconnectHandling(generation: generation)
        }
    }

    private func scheduleDisconnectHandling(generation: Int) {
        Task { @MainActor [weak self] in
            self?.handleDisconnectOnMain(generation: generation)
        }
    }

    @MainActor
    private func handleDisconnectOnMain(generation: Int) {
        guard OpenClawDisconnectPolicy.shouldHandle(
            callbackGeneration: generation,
            currentGeneration: connectionGeneration,
            handledGeneration: handledDisconnectGeneration,
            isDisconnected: connectionState == .disconnected
        ) else { return }
        handledDisconnectGeneration = generation
        failPendingConversationForDisconnect()

        webSocketTransport?.cancel(closeCode: URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
        webSocketTransport = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isConnectionAttemptInFlight = false
        stableConnectionTask?.cancel()
        stableConnectionTask = nil

        guard shouldReconnect else {
            connectionState = .disconnected
            return
        }

        guard isApplicationActive else {
            pendingForegroundReconnect = true
            connectionState = .disconnected
            print("[OpenClaw][INFO] 앱 비활성 상태라 재연결 카운터 증가 없이 보류")
            return
        }

        reconnectAttempts += 1
        if reconnectAttempts > Self.maxReconnectAttempts {
            print("[OpenClaw][ERROR] 최대 재연결 횟수 초과 attempts=\(Self.maxReconnectAttempts)")
            connectionState = .error("연결에 실패했습니다. \(Self.maxReconnectAttempts)회 재시도했습니다")
            shouldReconnect = false
            isEnabled = false
            saveSettings()
            return
        }

        let delay = min(Double(1 << reconnectAttempts), 30.0)
        print("[OpenClaw][WARN] 재연결 예약 attempt=\(reconnectAttempts)/\(Self.maxReconnectAttempts) delay=\(delay)s")
        connectionState = .disconnected
        scheduleReconnect(delay: delay)
    }

    private func scheduleReconnect(delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.shouldReconnect else { return }
                self.reconnectTask = nil
                guard self.prepareConnectionAttempt(reason: "scheduledReconnect") else { return }
                self.startConnection()
            }
        }
    }

    // MARK: - Image size control

    private func compressedImageData(_ image: UIImage) -> Data? {
        guard let jpegData = image.jpegData(compressionQuality: 1.0) else {
            return nil
        }
        return OpenClawImageAttachmentPreparer.prepareJPEGData(jpegData)
    }
}

// MARK: - Endpoint validation

enum OpenClawGatewayEndpoint {
    static func makeURL(
        rawHost: String,
        defaultPort: Int,
        transportMode: OpenClawTransportMode
    ) throws -> URL {
        let trimmedHost = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw OpenClawTransportError.invalidHost
        }
        guard (1...65_535).contains(defaultPort) else {
            throw OpenClawTransportError.invalidPort(defaultPort)
        }

        let hasExplicitScheme = trimmedHost.contains("://")
        let suppliedComponents: URLComponents?
        if hasExplicitScheme {
            guard let components = URLComponents(string: trimmedHost),
                  let parsedHost = components.host,
                  !parsedHost.isEmpty else {
                throw OpenClawTransportError.invalidHost
            }
            suppliedComponents = components
        } else {
            guard !containsUnsafeBareHostSyntax(trimmedHost) else {
                throw OpenClawTransportError.invalidHost
            }
            suppliedComponents = nil
        }

        guard suppliedComponents?.user == nil,
              suppliedComponents?.password == nil,
              suppliedComponents?.query == nil,
              suppliedComponents?.fragment == nil else {
            throw OpenClawTransportError.credentialsOrQueryNotAllowed
        }
        let host = suppliedComponents?.host ?? trimmedHost
        guard !host.isEmpty else {
            throw OpenClawTransportError.invalidHost
        }

        let port = suppliedComponents?.port ?? defaultPort
        guard (1...65_535).contains(port) else {
            throw OpenClawTransportError.invalidPort(port)
        }

        let requestedScheme = suppliedComponents?.scheme?.lowercased()
        let isMeshnetPeer = isMeshnetHost(host)
        let isLocalOrPrivate = isLocalOrPrivateHost(host)
        let canUsePlainWebSocket = isLocalOrPrivate
            || (transportMode == .meshnet && isMeshnetPeer)
        let defaultsToPlainWebSocket = isLocalOrPrivate
            || (transportMode == .meshnet && isMeshnetPeer)
        let scheme = requestedScheme ?? (defaultsToPlainWebSocket ? "ws" : "wss")
        guard scheme == "ws" || scheme == "wss" else {
            throw OpenClawTransportError.unsupportedScheme(scheme)
        }

        if scheme == "ws" && !canUsePlainWebSocket {
            if isMeshnetPeer {
                throw OpenClawTransportError.meshnetModeRequired
            }
            throw OpenClawTransportError.insecurePublicWebSocket
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = suppliedComponents?.path ?? ""

        guard let url = components.url else {
            throw OpenClawTransportError.invalidHost
        }
        return url
    }

    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        let normalized = normalizeHost(host)

        if normalized == "localhost" || normalized == "::1" || normalized.hasSuffix(".local") {
            return true
        }

        if let octets = strictIPv4Octets(normalized) {
            switch octets[0] {
            case 10, 127:
                return true
            case 169:
                return octets[1] == 254
            case 172:
                return (16...31).contains(octets[1])
            case 192:
                return octets[1] == 168
            default:
                return false
            }
        }

        // Hostname prefixes such as "10.attacker.example" must never be treated as an IP.
        // IPv6 private/link-local checks only run for actual colon-containing literals.
        guard normalized.contains(":") else {
            return false
        }

        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true // IPv6 unique-local fc00::/7
        }

        let firstHextet = normalized.split(separator: ":", omittingEmptySubsequences: true).first
            .flatMap { UInt16($0, radix: 16) }
        if let firstHextet,
           (firstHextet & 0xffc0) == 0xfe80 {
            return true // IPv6 link-local fe80::/10
        }

        return false
    }

    static func isMeshnetHost(_ host: String) -> Bool {
        guard let octets = strictIPv4Octets(normalizeHost(host)) else {
            return false
        }

        // Nord Meshnet addresses use the CGNAT range 100.64.0.0/10.
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func containsUnsafeBareHostSyntax(_ value: String) -> Bool {
        value.contains("/")
            || value.contains("?")
            || value.contains("#")
            || value.contains("@")
            || (value.contains(":") && !isBracketedIPv6Literal(value))
    }

    private static func isBracketedIPv6Literal(_ value: String) -> Bool {
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            return false
        }
        return value.dropFirst().dropLast().contains(":")
    }

    private static func normalizeHost(_ host: String) -> String {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Fully-qualified hostnames may legally end in a dot.
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func strictIPv4Octets(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }

        var octets: [Int] = []
        octets.reserveCapacity(4)

        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isNumber }),
                  let octet = Int(component),
                  (0...255).contains(octet) else {
                return nil
            }
            octets.append(octet)
        }
        return octets
    }
}

private enum OpenClawTransportError: LocalizedError {
    case invalidHost
    case invalidPort(Int)
    case unsupportedScheme(String)
    case insecurePublicWebSocket
    case meshnetModeRequired
    case credentialsOrQueryNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Gateway 호스트가 올바르지 않습니다"
        case .invalidPort:
            return "Gateway 포트가 올바르지 않습니다"
        case .unsupportedScheme:
            return "지원하지 않는 연결 방식입니다"
        case .insecurePublicWebSocket:
            return "공인망 호스트에는 암호화된 wss:// 연결만 사용할 수 있습니다"
        case .meshnetModeRequired:
            return "Meshnet 주소의 ws:// 연결은 설정에서 Meshnet 모드를 켠 경우에만 사용할 수 있습니다"
        case .credentialsOrQueryNotAllowed:
            return "Gateway 주소에는 사용자 정보, 토큰, 쿼리 문자열 또는 프래그먼트를 넣을 수 없습니다"
        }
    }
}

private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int {
        self != 0 ? self : defaultValue
    }
}

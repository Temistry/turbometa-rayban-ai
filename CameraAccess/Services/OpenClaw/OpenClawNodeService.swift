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

    private var webSocketTransport: OpenClawWebSocketTransport?
    private var connectionGeneration = 0
    private var handledDisconnectGeneration: Int?
    private var commandRouter: OpenClawCommandRouter?
    private var reconnectTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var nodeId: String
    private var pendingNonce: String?
    private var shouldReconnect = false
    private var reconnectAttempts = 0
    private lazy var deviceIdentity = OpenClawDeviceIdentityStore.loadOrCreate()

    private let keychainService = "com.smartview.glassai.openclaw"
    private let keychainAccount = "gateway_token"

    static let minimumProtocolVersion = 3
    static let maximumProtocolVersion = 4
    private static let tickInterval: TimeInterval = 15
    private static let maxReconnectAttempts = 5
    private static let maximumWebSocketMessageSize = 8 * 1024 * 1024
    private static let maximumImageUploadSize = 4 * 1024 * 1024

    private static let commands = [
        "camera.snap",
        "camera.list",
        "device.status",
        "device.info"
    ]

    private static let caps = ["camera"]

    private override init() {
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        self.nodeId = "rayban-\(deviceID.prefix(8))".lowercased()
        super.init()
        hardenStoredToken()
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
        guard connectionState != .connected && connectionState != .connecting else {
            print("[OpenClaw][WARN] 이미 연결 중이거나 연결됨 state=\(connectionState)")
            return
        }

        isEnabled = true
        shouldReconnect = true
        reconnectAttempts = 0
        saveSettings()
        startConnection()
    }

    func disconnect() {
        shouldReconnect = false
        isEnabled = false
        saveSettings()

        reconnectTask?.cancel()
        reconnectTask = nil
        tickTask?.cancel()
        tickTask = nil

        webSocketTransport?.cancel(closeCode: URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
        webSocketTransport = nil
        connectionGeneration += 1
        handledDisconnectGeneration = connectionGeneration

        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
        print("[OpenClaw][INFO] 사용자가 연결을 해제함")
    }

    func sendChatMessage(_ text: String, image: UIImage? = nil) {
        guard connectionState == .connected else {
            print("[OpenClaw][WARN] 연결되지 않아 채팅 전송 취소 textLength=\(text.count)")
            return
        }

        var attachments: [[String: Any]] = []
        var imageBytes = 0

        if let image {
            if let jpegData = compressedImageData(image) {
                imageBytes = jpegData.count
                attachments.append([
                    "type": "image",
                    "mimeType": "image/jpeg",
                    "content": jpegData.base64EncodedString()
                ])
            } else {
                print("[OpenClaw][ERROR] 첨부 이미지를 제한 크기 이하로 압축하지 못해 텍스트만 전송")
            }
        }

        var params: [String: Any] = [
            "sessionKey": chatSessionKey,
            "message": text,
            "idempotencyKey": UUID().uuidString
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments
        }

        sendJSON([
            "type": "req",
            "id": UUID().uuidString,
            "method": "chat.send",
            "params": params
        ])

        // 사용자 대화 내용은 로그에 남기지 않는다.
        print("[OpenClaw][INFO] 채팅 전송 textLength=\(text.count) imageBytes=\(imageBytes)")
    }

    private var chatSessionKey = "turbometa-chat"
    var onChatEvent: ((String) -> Void)?

    // MARK: - Gateway token

    func saveGatewayToken(_ token: String) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !normalizedToken.isEmpty,
              let data = normalizedToken.data(using: .utf8) else {
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
            print("[OpenClaw][INFO] Gateway 토큰을 기기 전용 Keychain에 저장")
        } else {
            print("[OpenClaw][ERROR] Gateway 토큰 저장 실패 status=\(status)")
        }
    }

    func loadGatewayToken() -> String? {
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
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                print("[OpenClaw][WARN] Gateway 토큰 읽기 실패 status=\(status)")
            }
            return nil
        }
        return token
    }

    private func hardenStoredToken() {
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
            print("[OpenClaw][WARN] 기존 Gateway 토큰 접근 정책 강화 실패 status=\(status)")
        }
    }

    // MARK: - Connection

    private func startConnection() {
        let url: URL
        do {
            url = try makeGatewayURL()
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
                self.connectionState = .error(message)
            }
            shouldReconnect = false
            print("[OpenClaw][ERROR] Gateway URL 검증 실패 description=\(message) port=\(gatewayPort) mode=\(transportMode.rawValue)")
            return
        }

        DispatchQueue.main.async {
            self.connectionState = .connecting
        }

        let transportKind = OpenClawWebSocketTransportSelector.kind(
            for: url,
            transportMode: transportMode
        )
        connectionGeneration += 1
        let generation = connectionGeneration
        handledDisconnectGeneration = nil

        // 토큰은 URL 쿼리에 넣지 않는다. URL은 각종 프록시와 진단 로그에 남기 쉽기 때문이다.
        print("[OpenClaw][INFO] Gateway 연결 시작 scheme=\(url.scheme ?? "-") port=\(url.port ?? gatewayPort) mode=\(transportMode.rawValue) transport=\(transportKind.rawValue) tokenConfigured=\(loadGatewayToken() != nil)")

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
                print("[OpenClaw][ERROR] 수신 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) socketState=\(String(describing: state)) reconnect=\(self.shouldReconnect)")

                if state == .canceling || state == .completed || !self.shouldReconnect {
                    return
                }
                self.scheduleDisconnectHandling(generation: generation)
            }
        }
    }

    private func sendJSON(_ dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let text = String(data: data, encoding: .utf8) else {
            print("[OpenClaw][ERROR] 전송 JSON 직렬화 실패")
            return
        }

        guard let transport = webSocketTransport, transport.state == .running else {
            print("[OpenClaw][ERROR] WebSocket이 실행 중이 아니어서 전송 실패 state=\(String(describing: self.webSocketTransport?.state))")
            return
        }

        let generation = connectionGeneration
        transport.send(.string(text)) { [weak self] error in
            guard let error else { return }
            let nsError = error as NSError
            print("[OpenClaw][ERROR] 전송 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
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

        if type == "res" {
            let ok = json["ok"] as? Bool ?? false
            if ok {
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

        let token = loadGatewayToken() ?? ""
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
            token: token.isEmpty ? nil : token,
            nonce: nonce,
            platform: platform,
            deviceFamily: nil
        )

        var auth: [String: Any] = [:]
        if !token.isEmpty {
            auth["token"] = token
        }

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
        print("[OpenClaw][INFO] 서명된 연결 요청 전송 tokenConfigured=\(!token.isEmpty)")
    }

    private func handleHelloOK(json: [String: Any]) {
        DispatchQueue.main.async {
            self.connectionState = .connected
            self.reconnectAttempts = 0
        }
        print("[OpenClaw][INFO] Gateway 연결 성공")
        startTickWatchdog()
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
                if !text.isEmpty {
                    DispatchQueue.main.async {
                        self.onChatEvent?(state == "final" ? "[[FINAL]]\(text)" : text)
                    }
                    print("[OpenClaw][INFO] 채팅 응답 전달 state=\(state) textLength=\(text.count)")
                }
            }

        case "tick", "health":
            break

        default:
            print("[OpenClaw][INFO] 기타 이벤트 method=\(method)")
        }
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
        guard !ok else { return }

        let error = json["error"] as? [String: Any]
        let code = error?["code"] as? String ?? "UNKNOWN"
        let message = error?["message"] as? String ?? "설명 없음"
        print("[OpenClaw][ERROR] Gateway 응답 오류 requestID=\(id.prefix(8)) code=\(code) message=\(message)")

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

    private func startTickWatchdog() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.sendJSON([
                    "type": "req",
                    "id": UUID().uuidString,
                    "method": "tick",
                    "params": ["ts": Int64(Date().timeIntervalSince1970 * 1_000)]
                ])
            }
        }
    }

    private func handleTransportFailure(_ error: Error, generation: Int) {
        guard connectionGeneration == generation else { return }
        let nsError = error as NSError
        print("[OpenClaw][ERROR] 연결 작업 종료 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

        if shouldReconnect {
            DispatchQueue.main.async {
                self.connectionState = .error("Gateway 네트워크 연결 오류: \(nsError.localizedDescription)")
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
        guard connectionGeneration == generation,
              handledDisconnectGeneration != generation,
              connectionState != .disconnected else { return }
        handledDisconnectGeneration = generation

        webSocketTransport?.cancel(closeCode: URLSessionWebSocketTask.CloseCode.goingAway.rawValue)
        webSocketTransport = nil
        tickTask?.cancel()
        tickTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        guard shouldReconnect else {
            connectionState = .disconnected
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
                self.startConnection()
            }
        }
    }

    // MARK: - Image size control

    private func compressedImageData(_ image: UIImage) -> Data? {
        for quality in [0.70, 0.55, 0.40, 0.30] {
            if let data = image.jpegData(compressionQuality: quality),
               data.count <= Self.maximumImageUploadSize {
                return data
            }
        }
        return nil
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

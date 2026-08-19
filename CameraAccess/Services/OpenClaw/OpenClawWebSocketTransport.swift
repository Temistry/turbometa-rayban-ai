/*
 * OpenClaw WebSocket Transports
 *
 * 일반 연결은 URLSession을 사용하고, 승인된 Nord Meshnet IPv4의 평문 연결만
 * Network.framework로 분리한다. OpenClaw 인증과 메시지 처리는 상위 서비스가 담당한다.
 */

import Foundation
import Network

enum OpenClawWebSocketMessage {
    case string(String)
    case data(Data)
}

enum OpenClawWebSocketTransportState: String {
    case setup
    case connecting
    case running
    case canceling
    case completed
}

enum OpenClawWebSocketTransportKind: String {
    case urlSession
    case meshnetNetwork
}

protocol OpenClawWebSocketTransport: AnyObject {
    var state: OpenClawWebSocketTransportState { get }
    var onOpen: (() -> Void)? { get set }
    var onClose: ((Int, String?) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    func start()
    func receive(completion: @escaping (Result<OpenClawWebSocketMessage, Error>) -> Void)
    func send(_ message: OpenClawWebSocketMessage, completion: @escaping (Error?) -> Void)
    func cancel(closeCode: Int)
}

enum OpenClawWebSocketTransportSelector {
    static func kind(
        for url: URL,
        transportMode: OpenClawTransportMode
    ) -> OpenClawWebSocketTransportKind {
        guard transportMode == .meshnet,
              url.scheme?.lowercased() == "ws",
              let host = url.host,
              OpenClawGatewayEndpoint.isMeshnetHost(host) else {
            return .urlSession
        }
        return .meshnetNetwork
    }
}

final class OpenClawURLSessionWebSocketTransport: NSObject, OpenClawWebSocketTransport {
    private(set) var state: OpenClawWebSocketTransportState = .setup
    var onOpen: (() -> Void)?
    var onClose: ((Int, String?) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let url: URL
    private let maximumMessageSize: Int
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var didFinish = false

    init(url: URL, maximumMessageSize: Int) {
        self.url = url
        self.maximumMessageSize = maximumMessageSize
    }

    func start() {
        guard state == .setup else { return }
        state = .connecting

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.name = "openclaw-ws"
        delegateQueue.maxConcurrentOperationCount = 1

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        self.session = session
        self.task = task
        task.resume()
    }

    func receive(completion: @escaping (Result<OpenClawWebSocketMessage, Error>) -> Void) {
        guard let task else {
            completion(.failure(OpenClawWebSocketTransportError.notConnected))
            return
        }
        task.receive { result in
            completion(result.map { message in
                switch message {
                case .string(let text):
                    return .string(text)
                case .data(let data):
                    return .data(data)
                @unknown default:
                    return .data(Data())
                }
            })
        }
    }

    func send(_ message: OpenClawWebSocketMessage, completion: @escaping (Error?) -> Void) {
        guard let task else {
            completion(OpenClawWebSocketTransportError.notConnected)
            return
        }

        let taskMessage: URLSessionWebSocketTask.Message
        switch message {
        case .string(let text):
            taskMessage = .string(text)
        case .data(let data):
            taskMessage = .data(data)
        }
        task.send(taskMessage, completionHandler: completion)
    }

    func cancel(closeCode: Int) {
        guard state != .completed else { return }
        state = .canceling
        let code = URLSessionWebSocketTask.CloseCode(rawValue: closeCode) ?? .goingAway
        task?.cancel(with: code, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        state = .completed
    }

    private func finishWithFailure(_ error: Error) {
        guard !didFinish else { return }
        didFinish = true
        state = .completed
        onFailure?(error)
    }
}

extension OpenClawURLSessionWebSocketTransport: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        state = .running
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard !didFinish else { return }
        didFinish = true
        state = .completed
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        onClose?(closeCode.rawValue, reasonText)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finishWithFailure(error)
    }
}

final class OpenClawMeshnetWebSocketTransport: OpenClawWebSocketTransport {
    private(set) var state: OpenClawWebSocketTransportState = .setup
    var onOpen: (() -> Void)?
    var onClose: ((Int, String?) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "openclaw-meshnet-ws")
    private let maximumMessageSize: Int
    private var timeoutWorkItem: DispatchWorkItem?
    private var didFinish = false

    init(url: URL, maximumMessageSize: Int) throws {
        guard url.scheme?.lowercased() == "ws",
              let host = url.host,
              OpenClawGatewayEndpoint.isMeshnetHost(host),
              let rawPort = url.port,
              UInt16(exactly: rawPort) != nil else {
            throw OpenClawWebSocketTransportError.invalidMeshnetEndpoint
        }

        self.maximumMessageSize = maximumMessageSize

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = maximumMessageSize

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        // URL endpoint를 사용해야 WebSocket upgrade 요청에 경로가 보존된다.
        self.connection = NWConnection(to: .url(url), using: parameters)
    }

    func start() {
        guard state == .setup else { return }
        state = .connecting

        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.finishTimeout()
                self.state = .running
                self.onOpen?()
            case .failed(let error):
                self.finishWithFailure(error)
            case .cancelled:
                self.finishClose(code: 1001, reason: nil)
            default:
                break
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.finishWithFailure(OpenClawWebSocketTransportError.connectionTimedOut)
            self.connection.cancel()
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.start(queue: queue)
    }

    func receive(completion: @escaping (Result<OpenClawWebSocketMessage, Error>) -> Void) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }

            guard let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata else {
                completion(.failure(OpenClawWebSocketTransportError.missingWebSocketMetadata))
                return
            }

            let data = content ?? Data()
            guard data.count <= self.maximumMessageSize else {
                completion(.failure(OpenClawWebSocketTransportError.messageTooLarge))
                return
            }

            switch metadata.opcode {
            case .text:
                guard let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(OpenClawWebSocketTransportError.invalidTextFrame))
                    return
                }
                completion(.success(.string(text)))
            case .binary:
                completion(.success(.data(data)))
            case .close:
                self.finishClose(
                    code: 1000,
                    reason: String(data: data, encoding: .utf8)
                )
            case .ping, .pong:
                self.queue.async { [weak self] in
                    self?.receive(completion: completion)
                }
            default:
                completion(.failure(OpenClawWebSocketTransportError.unsupportedFrame))
            }
        }
    }

    func send(_ message: OpenClawWebSocketMessage, completion: @escaping (Error?) -> Void) {
        guard state == .running else {
            completion(OpenClawWebSocketTransportError.notConnected)
            return
        }

        let data: Data
        let opcode: NWProtocolWebSocket.Opcode
        switch message {
        case .string(let text):
            data = Data(text.utf8)
            opcode = .text
        case .data(let value):
            data = value
            opcode = .binary
        }

        guard data.count <= maximumMessageSize else {
            completion(OpenClawWebSocketTransportError.messageTooLarge)
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(
            identifier: "openclaw-message",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                completion(error)
            }
        )
    }

    func cancel(closeCode: Int) {
        guard state != .completed else { return }
        finishTimeout()
        state = .canceling
        connection.cancel()
    }

    private func finishWithFailure(_ error: Error) {
        guard !didFinish else { return }
        didFinish = true
        finishTimeout()
        state = .completed
        onFailure?(error)
    }

    private func finishClose(code: Int, reason: String?) {
        guard !didFinish else { return }
        didFinish = true
        finishTimeout()
        state = .completed
        onClose?(code, reason)
    }

    private func finishTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
}

enum OpenClawWebSocketTransportError: LocalizedError {
    case invalidMeshnetEndpoint
    case connectionTimedOut
    case notConnected
    case missingWebSocketMetadata
    case messageTooLarge
    case invalidTextFrame
    case unsupportedFrame

    var errorDescription: String? {
        switch self {
        case .invalidMeshnetEndpoint:
            return "Meshnet WebSocket 주소가 올바르지 않습니다"
        case .connectionTimedOut:
            return "Meshnet Gateway 연결 시간이 초과되었습니다"
        case .notConnected:
            return "WebSocket이 연결되지 않았습니다"
        case .missingWebSocketMetadata:
            return "WebSocket 프레임 정보를 읽을 수 없습니다"
        case .messageTooLarge:
            return "WebSocket 메시지가 허용 크기를 초과했습니다"
        case .invalidTextFrame:
            return "WebSocket 텍스트 프레임이 올바르지 않습니다"
        case .unsupportedFrame:
            return "지원하지 않는 WebSocket 프레임입니다"
        }
    }
}

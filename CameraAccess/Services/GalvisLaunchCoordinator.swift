import Foundation

@MainActor
final class GalvisLaunchCoordinator: ObservableObject {
    static let shared = GalvisLaunchCoordinator()

    @Published private(set) var isAppReady = false
    @Published var isOpenClawSessionPresented = false
    @Published var isOpenClawChatPresented = false
    @Published private(set) var selectedOpenClawMessageID: UUID?

    private var hasPendingOpenClawRequest = false
    private var hasPendingOpenClawChatRequest = false

    init() {}

    func requestOpenClawSession() {
        hasPendingOpenClawRequest = true
        print("[Galvis][ROUTE] 음성 대화 요청 ready=\(isAppReady)")
        presentPendingRequestIfReady()
    }

    func requestOpenClawChat(messageID: UUID? = nil) {
        selectedOpenClawMessageID = messageID
        hasPendingOpenClawChatRequest = true
        print("[Galvis][ROUTE] 채팅 요청 ready=\(isAppReady) selectedMessage=\(messageID != nil)")
        presentPendingRequestIfReady()
    }

    func markAppReady() {
        isAppReady = true
        print("[Galvis][ROUTE] 앱 화면 준비 완료")
        presentPendingRequestIfReady()
    }

    func dismissOpenClawSession() {
        isOpenClawSessionPresented = false
        print("[Galvis][ROUTE] 음성 대화 화면 종료")
        presentPendingRequestIfReady()
    }

    func dismissOpenClawChat() {
        isOpenClawChatPresented = false
        selectedOpenClawMessageID = nil
        print("[Galvis][ROUTE] 채팅 화면 종료")
        presentPendingRequestIfReady()
    }

    private func presentPendingRequestIfReady() {
        guard isAppReady else { return }
        guard !isOpenClawSessionPresented, !isOpenClawChatPresented else { return }

        if hasPendingOpenClawRequest {
            hasPendingOpenClawRequest = false
            isOpenClawSessionPresented = true
            print("[Galvis][ROUTE] 음성 대화 화면 표시")
            return
        }

        if hasPendingOpenClawChatRequest {
            hasPendingOpenClawChatRequest = false
            isOpenClawChatPresented = true
            print("[Galvis][ROUTE] 채팅 화면 표시")
        }
    }
}

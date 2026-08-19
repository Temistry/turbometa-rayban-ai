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

    private init() {}

    func requestOpenClawSession() {
        hasPendingOpenClawRequest = true
        presentPendingRequestIfReady()
    }

    func requestOpenClawChat(messageID: UUID? = nil) {
        selectedOpenClawMessageID = messageID
        hasPendingOpenClawChatRequest = true
        presentPendingRequestIfReady()
    }

    func markAppReady() {
        isAppReady = true
        presentPendingRequestIfReady()
    }

    func dismissOpenClawSession() {
        isOpenClawSessionPresented = false
    }

    func dismissOpenClawChat() {
        isOpenClawChatPresented = false
        selectedOpenClawMessageID = nil
    }

    private func presentPendingRequestIfReady() {
        guard isAppReady else { return }

        if hasPendingOpenClawChatRequest {
            hasPendingOpenClawChatRequest = false
            isOpenClawChatPresented = true
        }

        if hasPendingOpenClawRequest {
            hasPendingOpenClawRequest = false
            isOpenClawSessionPresented = true
        }
    }
}

import Foundation

@MainActor
final class GalvisLaunchCoordinator: ObservableObject {
    static let shared = GalvisLaunchCoordinator()

    @Published private(set) var isAppReady = false
    @Published var isOpenClawSessionPresented = false

    private var hasPendingOpenClawRequest = false

    private init() {}

    func requestOpenClawSession() {
        hasPendingOpenClawRequest = true
        presentPendingRequestIfReady()
    }

    func markAppReady() {
        isAppReady = true
        presentPendingRequestIfReady()
    }

    func dismissOpenClawSession() {
        isOpenClawSessionPresented = false
    }

    private func presentPendingRequestIfReady() {
        guard isAppReady, hasPendingOpenClawRequest else { return }
        hasPendingOpenClawRequest = false
        isOpenClawSessionPresented = true
    }
}

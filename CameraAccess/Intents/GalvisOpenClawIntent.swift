import AppIntents

@available(iOS 16.0, *)
struct GalvisOpenClawIntent: AppIntent {
    static var title: LocalizedStringResource = "갈비스 OpenClaw"
    static var description = IntentDescription("TurboMeta를 열고 OpenClaw 음성 대화를 시작합니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        GalvisLaunchCoordinator.shared.requestOpenClawSession()
        return .result(dialog: "갈비스 OpenClaw 음성 대화를 시작합니다")
    }
}

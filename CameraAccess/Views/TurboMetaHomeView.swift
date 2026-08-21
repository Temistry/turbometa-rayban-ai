/*
 * TurboMeta Home View
 * 主页 - 功能入口
 */

import SwiftUI

struct TurboMetaHomeView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @StateObject private var quickVisionManager = QuickVisionManager.shared
    let apiKey: String

    @State private var showLeanEat = false
    @State private var showQuickVision = false
    @State private var modePickerFlow: OpenClawCaptureModePickerView.Flow?
    @State private var quickShotLaunch: QuickShotLaunch?
    @ObservedObject private var openClawService = OpenClawNodeService.shared
    @ObservedObject private var galvisLaunchCoordinator = GalvisLaunchCoordinator.shared
    @ObservedObject private var modeManager = OpenClawCaptureModeManager.shared

    private struct QuickShotLaunch: Identifiable {
        let id = UUID()
        let flow: OpenClawQuickShotCoordinator.Flow
        let snapshot: OpenClawCaptureModeExecutionSnapshot
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        AppColors.primary.opacity(0.1),
                        AppColors.secondary.opacity(0.1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppSpacing.lg) {
                        // Header
                        VStack(spacing: AppSpacing.sm) {
                            Text("app.name".localized)
                                .font(AppTypography.largeTitle)
                                .foregroundColor(AppColors.textPrimary)

                            Text("app.subtitle".localized)
                                .font(AppTypography.callout)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding(.top, AppSpacing.xl)

                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OpenClaw Quick Shot")
                                    .font(AppTypography.title2)
                                    .foregroundColor(AppColors.textPrimary)
                                Text(quickShotReadinessText)
                                    .font(AppTypography.caption)
                                    .foregroundColor(quickShotIsReady ? .green : AppColors.textSecondary)
                            }
                            .padding(.horizontal, 2)

                            HStack(spacing: AppSpacing.md) {
                                QuickShotCard(
                                    title: "사진",
                                    modeName: currentPhotoModeName,
                                    icon: "camera.fill",
                                    gradient: [Color.purple, Color.indigo],
                                    isEnabled: quickShotIsReady,
                                    onCapture: { launchCurrentQuickShot(flow: .photo) },
                                    onChangeMode: { modePickerFlow = .photo }
                                )

                                QuickShotCard(
                                    title: "동영상",
                                    modeName: currentVideoModeName,
                                    icon: "video.fill",
                                    gradient: [Color.indigo, Color.blue],
                                    isEnabled: quickShotIsReady,
                                    onCapture: { launchCurrentQuickShot(flow: .video) },
                                    onChangeMode: { modePickerFlow = .video }
                                )
                            }

                            HStack(spacing: AppSpacing.md) {
                                FeatureCard(
                                    title: "home.quickvision.title".localized,
                                    subtitle: "home.quickvision.subtitle".localized,
                                    icon: "eye.circle.fill",
                                    gradient: [Color.purple, Color.purple.opacity(0.7)]
                                ) {
                                    showQuickVision = true
                                }

                                FeatureCard(
                                    title: "OpenClaw",
                                    subtitle: openClawService.connectionState == .connected ? "home.openclaw.connected".localized : "home.openclaw.subtitle".localized,
                                    icon: "waveform.circle.fill",
                                    gradient: [Color.purple, Color.indigo]
                                ) {
                                    galvisLaunchCoordinator.requestOpenClawSession()
                                }
                            }

                            FeatureCardWide(
                                title: "home.leaneat.title".localized,
                                subtitle: "home.leaneat.subtitle".localized,
                                icon: "chart.bar.fill",
                                gradient: [AppColors.leanEat, AppColors.leanEat.opacity(0.7)]
                            ) {
                                showLeanEat = true
                            }
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.xl)
                    }
                }
            }
            .navigationBarHidden(true)
            .fullScreenCover(isPresented: $showLeanEat) {
                StreamView(viewModel: streamViewModel, wearablesVM: wearablesViewModel)
            }
            .fullScreenCover(isPresented: $showQuickVision) {
                QuickVisionView(streamViewModel: streamViewModel, apiKey: apiKey)
            }
            .sheet(item: $modePickerFlow) { flow in
                OpenClawCaptureModePickerView(
                    flow: flow,
                    modeManager: modeManager
                ) { snapshot in
                    launchQuickShot(flow: flow, snapshot: snapshot)
                }
            }
            .fullScreenCover(item: $quickShotLaunch) { launch in
                OpenClawQuickShotView(
                    flow: launch.flow,
                    snapshot: launch.snapshot,
                    streamViewModel: streamViewModel
                )
            }
        }
        .onAppear {
            quickVisionManager.setStreamViewModel(streamViewModel)
            openClawService.refreshGatewayTokenState()

            if openClawService.connectionState == .disconnected,
               openClawService.isGatewayTokenConfigured {
                openClawService.ensureConnected(reason: "TurboMetaHomeView.onAppear")
            }
        }
    }

    private var quickShotIsReady: Bool {
        streamViewModel.hasActiveDevice
            && openClawService.isGatewayTokenConfigured
    }

    private var quickShotReadinessText: String {
        guard streamViewModel.hasActiveDevice else {
            return "스마트 안경을 연결하면 촬영할 수 있습니다."
        }
        guard openClawService.isGatewayTokenConfigured else {
            return "OpenClaw Gateway 설정이 필요합니다."
        }
        return openClawService.connectionState == .connected
            ? "안경과 OpenClaw가 준비되었습니다."
            : "촬영 전 OpenClaw 연결을 확인합니다."
    }

    private var currentPhotoModeName: String {
        guard let id = modeManager.effectivePhotoModeId() else { return "일반" }
        return modeManager.mode(for: id)?.name ?? "일반"
    }

    private var currentVideoModeName: String {
        guard let id = modeManager.effectiveVideoModeId() else { return "일반" }
        return modeManager.mode(for: id)?.name ?? "일반"
    }

    private func launchCurrentQuickShot(flow: OpenClawCaptureModePickerView.Flow) {
        let modeID: UUID?
        switch flow {
        case .photo:
            modeID = modeManager.effectivePhotoModeId()
        case .video:
            modeID = modeManager.effectiveVideoModeId()
        }
        guard let modeID,
              let snapshot = modeManager.makeExecutionSnapshot(for: modeID) else {
            modePickerFlow = flow
            return
        }
        launchQuickShot(flow: flow, snapshot: snapshot)
    }

    private func launchQuickShot(
        flow: OpenClawCaptureModePickerView.Flow,
        snapshot: OpenClawCaptureModeExecutionSnapshot
    ) {
        let quickShotFlow: OpenClawQuickShotCoordinator.Flow
        switch flow {
        case .photo:
            quickShotFlow = .photo
        case .video:
            quickShotFlow = .video
        }
        quickShotLaunch = QuickShotLaunch(
            flow: quickShotFlow,
            snapshot: snapshot
        )
    }
}

private struct QuickShotCard: View {
    let title: String
    let modeName: String
    let icon: String
    let gradient: [Color]
    let isEnabled: Bool
    let onCapture: () -> Void
    let onChangeMode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onCapture) {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: icon)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(modeName)
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .background(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!isEnabled)
            .accessibilityLabel("OpenClaw \(title) Quick Shot, 현재 모드 \(modeName)")
            .accessibilityHint(isEnabled ? "두 번 탭하면 즉시 촬영합니다." : "현재 촬영할 수 없습니다.")

            Button(action: onChangeMode) {
                Label("모드 변경", systemImage: "slider.horizontal.3")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(gradient.last?.opacity(0.92) ?? Color.indigo)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) 촬영 모드 변경")
        }
        .background(gradient.last ?? Color.indigo)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.lg))
        .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        .opacity(isEnabled ? 1 : 0.58)
    }
}

// MARK: - Feature Card

struct FeatureCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    var isPlaceholder: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.md) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text
                VStack(spacing: AppSpacing.xs) {
                    Text(title)
                        .font(AppTypography.headline)
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.8))
                }

                if isPlaceholder {
                    Text("home.comingsoon".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs)
                        .background(.white.opacity(0.2))
                        .cornerRadius(AppCornerRadius.sm)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        }
        .disabled(isPlaceholder)
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Feature Card Wide

struct FeatureCardWide: View {
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.lg) {
                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 64, height: 64)

                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    HStack(spacing: AppSpacing.sm) {
                        Text(title)
                            .font(AppTypography.title2)
                            .foregroundColor(.white)

                        if let badge = badge {
                            Text(badge)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.25))
                                .cornerRadius(4)
                        }
                    }

                    Text(subtitle)
                        .font(AppTypography.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(AppSpacing.lg)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

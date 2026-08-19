/*
 * OpenClaw Quick Shot View
 * 사진·동영상 즉시 촬영의 진행 상태와 안전한 취소를 표시한다.
 */

import SwiftUI

struct OpenClawQuickShotView: View {
    let flow: OpenClawQuickShotCoordinator.Flow
    let initialSnapshot: OpenClawCaptureModeExecutionSnapshot
    @ObservedObject var streamViewModel: StreamSessionViewModel

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: OpenClawQuickShotCoordinator
    @State private var didStart = false

    init(
        flow: OpenClawQuickShotCoordinator.Flow,
        snapshot: OpenClawCaptureModeExecutionSnapshot,
        streamViewModel: StreamSessionViewModel
    ) {
        self.flow = flow
        self.initialSnapshot = snapshot
        self.streamViewModel = streamViewModel
        _coordinator = StateObject(
            wrappedValue: OpenClawQuickShotCoordinator(
                streamViewModel: streamViewModel
            )
        )
    }

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [.purple.opacity(0.16), .indigo.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer(minLength: 12)

                    Image(systemName: flow == .photo ? "camera.circle.fill" : "video.circle.fill")
                        .font(.system(size: 88, weight: .regular))
                        .foregroundStyle(.purple, .purple.opacity(0.18))
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(
                            flow == .photo
                                ? "openclaw.quickshot.photo.title".localized
                                : "openclaw.quickshot.video.title".localized
                        )
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)

                        Label(initialSnapshot.name, systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    stateContent
                        .frame(maxWidth: .infinity)
                        .padding(20)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    Spacer()

                    actionButtons
                }
                .padding(24)
            }
            .navigationTitle("OpenClaw Quick Shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if coordinator.state.isActive {
                            coordinator.cancel()
                        }
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("close".localized)
                }
            }
        }
        .interactiveDismissDisabled(coordinator.state.isActive)
        .onAppear {
            guard !didStart else { return }
            didStart = true
            switch flow {
            case .photo:
                coordinator.startPhoto(snapshot: initialSnapshot)
            case .video:
                coordinator.startVideo(snapshot: initialSnapshot)
            }
        }
        .onDisappear {
            if coordinator.state.isActive {
                coordinator.cancel()
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch coordinator.state {
        case .idle:
            Text("openclaw.quickshot.state.idle".localized)
        case .preparing:
            progress("openclaw.quickshot.state.preparing".localized)
        case .capturing:
            progress("openclaw.quickshot.state.capturing".localized)
        case .recording(let elapsed):
            VStack(spacing: 12) {
                Text("openclaw.quickshot.state.recording".localized)
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Text(
                    "openclaw.quickshot.recording.elapsed".localized(
                        elapsed,
                        OpenClawVideoRecorder.maxDuration
                    )
                )
                    .font(.system(.title, design: .monospaced).bold())
                ProgressView(value: elapsed, total: OpenClawVideoRecorder.maxDuration)
                    .tint(.red)
                Text("openclaw.quickshot.recording.limit".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saving:
            progress("openclaw.quickshot.state.saving".localized)
        case .exportingToPhotos:
            progress("openclaw.quickshot.state.exporting".localized)
        case .sending:
            progress("openclaw.quickshot.state.sending".localized)
        case .awaitingResponse:
            progress("openclaw.quickshot.state.awaiting".localized)
        case .completed:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("openclaw.quickshot.completed".localized)
                    .font(.title2.bold())
                if flow == .video {
                    Text("openclaw.quickshot.video.samplednotice".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let message, _, let ambiguous):
            VStack(spacing: 10) {
                Image(systemName: ambiguous ? "questionmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(ambiguous ? .orange : .red)
                Text(
                    ambiguous
                        ? "openclaw.quickshot.failed.ambiguous.title".localized
                        : "openclaw.quickshot.failed.title".localized
                )
                    .font(.title2.bold())
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if ambiguous {
                    Text("openclaw.quickshot.failed.ambiguous.message".localized)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        case .cancelled:
            VStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("openclaw.quickshot.cancelled".localized)
                    .font(.title2.bold())
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch coordinator.state {
        case .recording:
            VStack(spacing: 12) {
                Button {
                    coordinator.stopVideo()
                } label: {
                    Label("openclaw.quickshot.recording.stop".localized, systemImage: "stop.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button("cancel".localized, role: .cancel) {
                    coordinator.cancel()
                }
            }
        case .preparing, .capturing, .saving, .exportingToPhotos, .sending, .awaitingResponse:
            Button("cancel".localized, role: .cancel) {
                coordinator.cancel()
            }
            .buttonStyle(.bordered)
        case .completed, .failed, .cancelled:
            Button {
                dismiss()
            } label: {
                Text("done".localized)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        case .idle:
            EmptyView()
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(text)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }
}

/*
 * OpenClaw Capture Mode Picker View
 * 拍摄模式选择器 - 拍照/录像前选择模式
 *
 * Presented from the capture flow to pick which mode's prompt should be
 * used for this shot. Filters the shared catalog by media type so photo
 * capture never offers a video-only mode and vice versa. Selecting a mode
 * records it as "last used" for that media type via the manager and hands
 * the caller an immutable OpenClawCaptureModeExecutionSnapshot rather than
 * a live catalog id — the caller should hold onto that snapshot for the
 * duration of the capture, since the catalog can keep changing (edits,
 * deletes, reorders) after the picker dismisses.
 */

import SwiftUI

struct OpenClawCaptureModePickerView: View {
    /// Which capture flow this picker is being shown for. Distinct from
    /// `OpenClawCaptureModeMedia` (a mode's own applicability) because a
    /// picker instance is always scoped to exactly one live flow — photo
    /// capture or video capture — never "both" at once.
    enum Flow: String, Identifiable {
        case photo
        case video

        var id: String { rawValue }
    }

    let flow: Flow
    @ObservedObject var modeManager: OpenClawCaptureModeManager
    /// Called with an immutable snapshot of the chosen mode after the user
    /// taps a row. Callers should retain this snapshot (not re-look-up the
    /// mode by id later) so an in-flight capture keeps using the prompt it
    /// started with even if the catalog changes afterward.
    var onSelect: (OpenClawCaptureModeExecutionSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    private var availableModes: [OpenClawCaptureMode] {
        switch flow {
        case .photo:
            return modeManager.photoModes
        case .video:
            return modeManager.videoModes
        }
    }

    private var selectedId: UUID? {
        flow == .video ? modeManager.effectiveVideoModeId() : modeManager.effectivePhotoModeId()
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink {
                        OpenClawCaptureModeSettingsView(
                            modeManager: modeManager,
                            wrapsInNavigationView: false
                        )
                    } label: {
                        Label(
                            "openclaw.capturemode.picker.manage".localized,
                            systemImage: "slider.horizontal.3"
                        )
                    }
                }

                if availableModes.isEmpty {
                    Text("openclaw.capturemode.picker.empty".localized)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(availableModes) { mode in
                        Button {
                            select(mode)
                        } label: {
                            row(for: mode)
                        }
                    }
                }
            }
            .navigationTitle("openclaw.capturemode.picker.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(for mode: OpenClawCaptureMode) -> some View {
        HStack {
            Image(systemName: mode.symbol)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(mode.name)
                    .foregroundColor(.primary)
                if !mode.summary.isEmpty {
                    Text(mode.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if mode.id == selectedId {
                Image(systemName: "checkmark")
                    .foregroundColor(.blue)
            }
        }
    }

    private func select(_ mode: OpenClawCaptureMode) {
        switch flow {
        case .photo:
            modeManager.recordLastPhotoMode(mode.id)
        case .video:
            modeManager.recordLastVideoMode(mode.id)
        }
        if let snapshot = modeManager.makeExecutionSnapshot(for: mode.id) {
            onSelect(snapshot)
        }
        dismiss()
    }
}

/*
 * OpenClaw Capture Mode Settings View
 * 拍摄模式管理 - 新建/编辑/复制/删除/排序，设置拍照与录像默认模式
 */

import SwiftUI

struct OpenClawCaptureModeSettingsView: View {
    @ObservedObject var modeManager: OpenClawCaptureModeManager
    @Environment(\.dismiss) private var dismiss

    @State private var editorTarget: OpenClawCaptureModeEditorView.Mode?
    @State private var pendingDelete: OpenClawCaptureMode?

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(sortedModes) { mode in
                        modeRow(mode)
                    }
                    .onMove(perform: moveModes)
                } header: {
                    Text("openclaw.capturemode.settings.modes".localized)
                } footer: {
                    Text("openclaw.capturemode.settings.modes.footer.v2".localized)
                }

                Section {
                    Picker("openclaw.capturemode.settings.photodefault".localized, selection: photoDefaultBinding) {
                        ForEach(modeManager.photoModes) { mode in
                            Text(mode.name).tag(mode.id)
                        }
                    }

                    Picker("openclaw.capturemode.settings.videodefault".localized, selection: videoDefaultBinding) {
                        ForEach(modeManager.videoModes) { mode in
                            Text(mode.name).tag(mode.id)
                        }
                    }
                } header: {
                    Text("openclaw.capturemode.settings.defaults".localized)
                }

                Section {
                    Button {
                        editorTarget = .create
                    } label: {
                        Label("openclaw.capturemode.settings.new".localized, systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("openclaw.capturemode.settings.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $editorTarget) { target in
                OpenClawCaptureModeEditorView(modeManager: modeManager, editMode: target)
            }
            .alert(
                "openclaw.capturemode.delete.title".localized,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { mode in
                Button("cancel".localized, role: .cancel) {}
                Button("delete".localized, role: .destructive) {
                    try? modeManager.deleteMode(id: mode.id)
                    pendingDelete = nil
                }
            } message: { mode in
                Text("openclaw.capturemode.delete.confirm".localized(mode.name))
            }
        }
    }

    // MARK: - Rows

    private var sortedModes: [OpenClawCaptureMode] {
        modeManager.modes.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func modeRow(_ mode: OpenClawCaptureMode) -> some View {
        HStack {
            Image(systemName: mode.symbol)
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mode.name)
                        .foregroundColor(.primary)
                    if mode.isBuiltIn {
                        Text("openclaw.capturemode.builtin.badge".localized)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if !mode.summary.isEmpty {
                    Text(mode.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editorTarget = .edit(mode)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // isBuiltIn is provenance only — built-in modes can be deleted
            // like any other. The manager guards against removing the very
            // last mode and auto-regenerates a General fallback if a
            // deletion would leave photo or video capture without any mode.
            Button(role: .destructive) {
                pendingDelete = mode
            } label: {
                Label("delete".localized, systemImage: "trash")
            }
            Button {
                try? modeManager.duplicateMode(id: mode.id)
            } label: {
                Label("openclaw.capturemode.duplicate".localized, systemImage: "plus.square.on.square")
            }
            .tint(.blue)
        }
    }

    // MARK: - Reorder

    private func moveModes(from source: IndexSet, to destination: Int) {
        var ids = sortedModes.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        modeManager.reorderModes(orderedIds: ids)
    }

    // MARK: - Default bindings

    private var photoDefaultBinding: Binding<UUID> {
        Binding(
            get: { modeManager.photoDefaultModeId },
            set: { modeManager.setPhotoDefault($0) }
        )
    }

    private var videoDefaultBinding: Binding<UUID> {
        Binding(
            get: { modeManager.videoDefaultModeId },
            set: { modeManager.setVideoDefault($0) }
        )
    }
}

// MARK: - Identifiable conformance for sheet(item:)

extension OpenClawCaptureModeEditorView.Mode: Identifiable {
    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let mode):
            return "edit-\(mode.id.uuidString)"
        }
    }
}

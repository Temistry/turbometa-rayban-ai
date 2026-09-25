/*
 * OpenClaw Capture Mode Editor View
 * 拍摄模式编辑器 - 新建 / 编辑模式（含内置模式）
 *
 * Explicit Save only: nothing is written to the manager until the user taps
 * Save, and any attempt to leave with unsaved changes prompts a discard
 * confirmation. Built-in modes are fully editable here — `isBuiltIn` is
 * provenance only, not a lock — so this view has no read-only mode; a
 * "Built-in" badge is shown for context but every field stays interactive.
 */

import SwiftUI

struct OpenClawCaptureModeEditorView: View {
    enum Mode {
        case create
        case edit(OpenClawCaptureMode)
    }

    @ObservedObject var modeManager: OpenClawCaptureModeManager
    let editMode: Mode
    /// Called after a successful save with the resulting mode.
    var onSaved: ((OpenClawCaptureMode) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var summary: String = ""
    @State private var prompt: String = ""
    @State private var symbol: String = ""
    @State private var supportsPhoto: Bool = true
    @State private var supportsVideo: Bool = true

    @State private var errorMessage: String?
    @State private var showDiscardConfirm = false

    private var isBuiltIn: Bool {
        if case .edit(let mode) = editMode {
            return mode.isBuiltIn
        }
        return false
    }

    private var navigationTitle: String {
        switch editMode {
        case .create:
            return "openclaw.capturemode.editor.new".localized
        case .edit:
            return "openclaw.capturemode.editor.edit".localized
        }
    }

    private var currentMedia: OpenClawCaptureModeMedia {
        var media: OpenClawCaptureModeMedia = []
        if supportsPhoto { media.insert(.photo) }
        if supportsVideo { media.insert(.video) }
        return media
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("openclaw.capturemode.field.name".localized, text: $name)
                    TextField("openclaw.capturemode.field.summary".localized, text: $summary)
                    TextField("openclaw.capturemode.field.symbol".localized, text: $symbol)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    HStack {
                        Text("openclaw.capturemode.section.details".localized)
                        if isBuiltIn {
                            Spacer()
                            Text("openclaw.capturemode.builtin.badge".localized)
                                .font(.caption2)
                        }
                    }
                } footer: {
                    Text("openclaw.capturemode.field.symbol.help".localized)
                }

                Section {
                    Toggle("openclaw.capturemode.media.photo".localized, isOn: $supportsPhoto)
                    Toggle("openclaw.capturemode.media.video".localized, isOn: $supportsVideo)
                } header: {
                    Text("openclaw.capturemode.section.media".localized)
                } footer: {
                    Text("openclaw.capturemode.field.media.help".localized)
                }

                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 160)
                        .font(.body)
                } header: {
                    Text("openclaw.capturemode.field.prompt".localized)
                } footer: {
                    Text("openclaw.capturemode.field.prompt.help".localized)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel".localized) {
                        attemptDismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("save".localized) {
                        save()
                    }
                }
            }
            .onAppear {
                loadInitialValues()
            }
            .confirmationDialog(
                "openclaw.capturemode.discard.title".localized,
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("openclaw.capturemode.discard.confirm".localized, role: .destructive) {
                    dismiss()
                }
                Button("cancel".localized, role: .cancel) {}
            } message: {
                Text("openclaw.capturemode.discard.message".localized)
            }
        }
    }

    // MARK: - Load

    private func loadInitialValues() {
        switch editMode {
        case .create:
            name = ""
            summary = ""
            prompt = ""
            symbol = "camera.circle"
            supportsPhoto = true
            supportsVideo = true
        case .edit(let mode):
            name = mode.name
            summary = mode.summary
            prompt = mode.prompt
            symbol = mode.symbol
            supportsPhoto = mode.supportedMedia.supportsPhoto
            supportsVideo = mode.supportedMedia.supportsVideo
        }
    }

    private var hasUnsavedChanges: Bool {
        switch editMode {
        case .create:
            return !name.isEmpty || !summary.isEmpty || !prompt.isEmpty || symbol != "camera.circle" || !supportsPhoto || !supportsVideo
        case .edit(let mode):
            return name != mode.name
                || summary != mode.summary
                || prompt != mode.prompt
                || symbol != mode.symbol
                || currentMedia != mode.supportedMedia
        }
    }

    // MARK: - Actions

    private func attemptDismiss() {
        if hasUnsavedChanges {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func save() {
        do {
            let saved: OpenClawCaptureMode
            switch editMode {
            case .create:
                saved = try modeManager.createMode(
                    name: name,
                    summary: summary,
                    prompt: prompt,
                    symbol: symbol,
                    supportedMedia: currentMedia
                )
            case .edit(let mode):
                try modeManager.updateMode(
                    id: mode.id,
                    name: name,
                    summary: summary,
                    prompt: prompt,
                    symbol: symbol,
                    supportedMedia: currentMedia
                )
                saved = modeManager.mode(for: mode.id) ?? mode
            }
            errorMessage = nil
            onSaved?(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

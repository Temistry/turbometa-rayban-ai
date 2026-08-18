/*
 * OpenClaw Chat View
 * OpenClaw AI와 대화
 * 지원: 안경 사진과 텍스트 입력
 */

import SwiftUI

struct OpenClawChatView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var openClawService = OpenClawNodeService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isSending = false
    @State private var showTextInput = false
    @State private var showClearHistoryConfirmation = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Connection status
                if openClawService.connectionState != .connected {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("openclaw.status.connecting".localized)
                            .font(.system(size: 13))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
                }

                // Messages list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(openClawService.chatMessages) { msg in
                                ChatBubble(message: msg).id(msg.id)
                            }
                            if !openClawService.pendingChatResponse.isEmpty {
                                ChatBubble(message: OpenClawChatMessage(
                                    role: "assistant", text: openClawService.pendingChatResponse, image: nil
                                ))
                            }
                        }
                        .padding()
                    }
                    .onChange(of: openClawService.chatMessages.count) { _ in
                        if let last = openClawService.chatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Bottom control area
                VStack(spacing: 12) {
                    // Main action buttons
                    HStack(spacing: 16) {
                        // Camera snap
                        Button {
                            Task { await snapAndSend() }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 22))
                                Text("openclaw.chat.snap".localized)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(isSending ? .gray : .purple)
                            .frame(width: 60, height: 60)
                        }
                        .disabled(isSending || openClawService.connectionState != .connected)

                        // Text input toggle
                        Button {
                            showTextInput.toggle()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "keyboard")
                                    .font(.system(size: 22))
                                Text("openclaw.chat.text".localized)
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.purple)
                            .frame(width: 60, height: 60)
                        }
                    }
                    .padding(.vertical, 4)

                    // Text input bar (toggleable)
                    if showTextInput {
                        HStack(spacing: 10) {
                            TextField("openclaw.chat.placeholder".localized, text: $inputText)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.send)
                                .onSubmit { sendText() }

                            Button {
                                sendText()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(inputText.isEmpty ? .gray : .purple)
                            }
                            .disabled(inputText.isEmpty || openClawService.connectionState != .connected)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
            }
            .navigationTitle("OpenClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(openClawService.connectionState == .connected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Button {
                            showClearHistoryConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                        }
                        .disabled(openClawService.chatMessages.isEmpty)

                        NavigationLink {
                            OpenClawSettingsView()
                        } label: {
                            Image(systemName: "gear")
                                .font(.system(size: 14))
                        }
                    }
                }
            }
        }
        .onAppear {
            if openClawService.connectionState != .connected,
               openClawService.loadGatewayToken() != nil {
                openClawService.connect()
            }
        }
        .alert(
            "openclaw.chat.history.clear".localized,
            isPresented: $showClearHistoryConfirmation
        ) {
            Button("cancel".localized, role: .cancel) {}
            Button("delete".localized, role: .destructive) {
                openClawService.clearChatHistory()
            }
        } message: {
            Text("openclaw.chat.history.clear.confirm".localized)
        }
    }

    // MARK: - Text

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        openClawService.sendChatMessage(text)
    }

    // MARK: - Camera

    private func snapAndSend() async {
        isSending = true
        defer { isSending = false }

        let needsStreamStop = !streamViewModel.isStreaming
        if needsStreamStop {
            await streamViewModel.handleStartStreaming()
            let deadline = Date().addingTimeInterval(5.0)
            while streamViewModel.currentVideoFrame == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        guard let frame = streamViewModel.currentVideoFrame else {
            openClawService.addLocalChatNotice(
                "openclaw.chat.noframe".localized
            )
            if needsStreamStop { await streamViewModel.stopSession() }
            return
        }

        let text = inputText.isEmpty ? "openclaw.chat.photoprompt".localized : inputText
        inputText = ""
        openClawService.sendChatMessage(text, image: frame)

        if needsStreamStop { await streamViewModel.stopSession() }
    }
}

// MARK: - Chat Bubble

private struct ChatBubble: View {
    let message: OpenClawChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: 200, maxHeight: 150)
                        .cornerRadius(12)
                        .clipped()
                } else if message.hadImage {
                    Label(
                        "openclaw.chat.image.attachment".localized,
                        systemImage: "photo"
                    )
                    .font(.caption)
                    .foregroundColor(message.role == "user" ? .white : .secondary)
                }

                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundColor(message.role == "user" ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == "user"
                            ? AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing))
                            : AnyShapeStyle(Color(.systemGray5))
                    )
                    .cornerRadius(18)
            }

            if message.role == "assistant" { Spacer(minLength: 60) }
        }
    }
}

/*
 * OpenClaw Gateway 연결 설정
 */

import SwiftUI

struct OpenClawSettingsView: View {
    @ObservedObject var nodeService = OpenClawNodeService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var portText = ""
    @State private var token = ""
    @State private var showValidationError = false
    @State private var validationMessage = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("연결 상태")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(statusText)
                                .font(AppTypography.caption)
                                .foregroundColor(statusColor)
                        }
                    }

                    if nodeService.connectionState == .waitingForPairing {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("openclaw.pairing.hint".localized)
                                .font(AppTypography.caption)
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                } header: {
                    Text("OpenClaw")
                }

                Section {
                    HStack {
                        Text("호스트")
                            .frame(width: 58, alignment: .leading)
                        TextField("127.0.0.1 또는 wss://gateway.example.com", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    HStack {
                        Text("포트")
                            .frame(width: 58, alignment: .leading)
                        TextField("18789", text: $portText)
                            .keyboardType(.numberPad)
                    }

                    SecureField("Gateway 토큰", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Gateway 설정")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("openclaw.gateway.help".localized)
                        Label(transportDescription, systemImage: transportSystemImage)
                            .foregroundColor(transportColor)
                    }
                }

                Section {
                    if nodeService.connectionState == .connected {
                        Button(role: .destructive) {
                            nodeService.disconnect()
                        } label: {
                            HStack {
                                Image(systemName: "wifi.slash")
                                Text("openclaw.disconnect".localized)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        Button {
                            saveAndConnect()
                        } label: {
                            HStack {
                                Image(systemName: "wifi")
                                Text("openclaw.connect".localized)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section {
                    InfoRow(
                        title: "노드 ID",
                        value: nodeService.connectionState == .connected ? "rayban-node" : "-"
                    )
                    InfoRow(
                        title: "허용 명령",
                        value: "사진 촬영, 기기 상태, 기기 정보"
                    )
                } header: {
                    Text("openclaw.capabilities".localized)
                } footer: {
                    Text("openclaw.capabilities.desc".localized)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("보안 정책", systemImage: "lock.shield.fill")
                            .font(AppTypography.headline)

                        Text("Gateway 토큰은 현재 iPhone에서만 복호화 가능한 Keychain에 저장됩니다. 토큰은 URL에 넣지 않으며 앱 로그에서도 마스킹됩니다.")
                            .font(AppTypography.caption)
                            .foregroundColor(.secondary)

                        Text("사설망의 ws:// 연결은 암호화되지 않습니다. 신뢰할 수 없는 Wi-Fi에서는 사용하지 말고, 외부 서버에는 반드시 wss://를 사용하세요.")
                            .font(AppTypography.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("OpenClaw 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                }
            }
            .alert("입력 오류", isPresented: $showValidationError) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .onAppear {
                host = nodeService.gatewayHost
                portText = "\(nodeService.gatewayPort)"
                token = nodeService.loadGatewayToken() ?? ""
            }
        }
    }

    private var statusColor: Color {
        switch nodeService.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .waitingForPairing: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var statusText: String {
        switch nodeService.connectionState {
        case .connected: return "openclaw.status.connected".localized
        case .connecting: return "openclaw.status.connecting".localized
        case .waitingForPairing: return "openclaw.status.pairing".localized
        case .disconnected: return "openclaw.status.disconnected".localized
        case .error(let message): return message
        }
    }

    private var normalizedHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let parsedHost = URLComponents(string: trimmed)?.host {
            return parsedHost
        }
        return trimmed
    }

    private var explicitScheme: String? {
        guard host.contains("://") else { return nil }
        return URLComponents(string: host)?.scheme?.lowercased()
    }

    private var isLocalOrPrivate: Bool {
        OpenClawNodeService.isLocalOrPrivateHost(normalizedHost)
    }

    private var transportDescription: String {
        if explicitScheme == "wss" {
            return "암호화된 wss:// 연결을 사용합니다"
        }
        if explicitScheme == "ws" || (explicitScheme == nil && isLocalOrPrivate) {
            return "사설망용 ws:// 연결입니다. 전송 내용은 암호화되지 않습니다"
        }
        return "공인망 호스트는 자동으로 wss:// 연결을 사용합니다"
    }

    private var transportSystemImage: String {
        explicitScheme == "wss" || (explicitScheme == nil && !isLocalOrPrivate)
            ? "lock.fill"
            : "exclamationmark.triangle.fill"
    }

    private var transportColor: Color {
        explicitScheme == "wss" || (explicitScheme == nil && !isLocalOrPrivate)
            ? .green
            : .orange
    }

    private func saveAndConnect() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            validationMessage = "Gateway 호스트를 입력하세요"
            showValidationError = true
            return
        }

        guard let port = Int(portText), (1...65_535).contains(port) else {
            validationMessage = "포트는 1부터 65535 사이의 숫자여야 합니다"
            showValidationError = true
            return
        }

        if explicitScheme == "ws" && !isLocalOrPrivate {
            validationMessage = "공인망 호스트에는 ws://를 사용할 수 없습니다. wss:// 주소를 입력하세요"
            showValidationError = true
            return
        }

        nodeService.gatewayHost = trimmedHost
        nodeService.gatewayPort = port
        nodeService.saveGatewayToken(token)
        nodeService.connect()
    }
}

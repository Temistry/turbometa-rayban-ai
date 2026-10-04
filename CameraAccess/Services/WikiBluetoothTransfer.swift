import SwiftUI
import CoreBluetooth
import CryptoKit
import Security

private enum WikiBLE {
    static let service = CBUUID(string: "AD67D421-08D9-4F22-AED2-EE0000000001")
    static let write = CBUUID(string: "AD67D421-08D9-4F22-AED2-EE0000000002")
    static let status = CBUUID(string: "AD67D421-08D9-4F22-AED2-EE0000000003")
}

@MainActor
final class WikiBluetoothTransfer: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var message = "PC 수신기를 켜고 연결 키를 입력하세요."
    @Published var busy = false
    @Published var progress = 0.0
    @Published var devices: [CBPeripheral] = []
    private var central: CBCentralManager!
    private var peer: CBPeripheral?
    private var write: CBCharacteristic?
    private var status: CBCharacteristic?
    private var payload = Data()
    private var cachedPlain = Data()
    private var cachedKey = Data()
    private var transferHash = ""
    private var secret: SymmetricKey?
    private var offset = 0
    private var sent = 0
    private var phase = ""
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func scan() {
        guard central.state == .poweredOn else { message = "Bluetooth 권한과 전원을 확인하세요."; return }
        devices = []; message = "가까운 PC 검색 중"
        central.scanForPeripherals(withServices: [WikiBLE.service])
        armTimeout()
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { cancel(); message = "Bluetooth 권한과 전원을 확인하세요." }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) { devices.append(peripheral) }
    }
    func send(_ meeting: ArchivedMeeting, to peripheral: CBPeripheral, keyText: String) {
        guard !busy, !meeting.lines.isEmpty else { return }
        let text = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Self.hex(text), keyData.count == 32 else { message = "PC에 표시된 64자리 연결 키를 입력하세요."; return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            struct Envelope: Encodable { let version: Int; let sessionID: String; let transcript: String; let record: ArchivedMeeting }
            let plain = try encoder.encode(Envelope(version: 1, sessionID: meeting.id.uuidString.lowercased(),
                transcript: MeetingArchiveService.exportText(meeting), record: meeting))
            let key = SymmetricKey(data: keyData)
            // Preserve the sealed payload for retrying the same content within this screen.
            let sealed = plain == cachedPlain && keyData == cachedKey && !payload.isEmpty
                ? payload : try AES.GCM.seal(plain, using: key).combined!
            guard sealed.count <= 2 * 1024 * 1024 else { message = "전송 한도 2MB를 넘었습니다. 파일 내보내기를 사용하세요."; return }
            payload = sealed; transferHash = SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
            cachedPlain = plain; cachedKey = keyData
            secret = key; offset = 0; progress = 0; busy = true; phase = "connecting"
            saveKey(keyData)
            peer = peripheral; peripheral.delegate = self
            central.stopScan(); central.connect(peripheral); message = "PC 연결 중"; armTimeout()
        } catch { fail("전송 파일을 준비하지 못했습니다.") }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([WikiBLE.service]); armTimeout()
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { fail("PC 연결 실패 · 다시 시도하세요.") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if busy { fail("연결 끊김 · 원본은 보관돼 있습니다. 다시 보내세요.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == WikiBLE.service }) else { fail("수신 서비스를 찾지 못했습니다."); return }
        peripheral.discoverCharacteristics([WikiBLE.write, WikiBLE.status], for: service); armTimeout()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { fail("수신 기능 확인 실패"); return }
        write = service.characteristics?.first { $0.uuid == WikiBLE.write }
        status = service.characteristics?.first { $0.uuid == WikiBLE.status }
        guard let write, status != nil, let secret, peripheral.maximumWriteValueLength(for: .withResponse) >= 69 else { fail("이 연결의 BLE 전송 크기를 지원하지 않습니다."); return }
        var header = Data([1]); header.append(Self.number(payload.count)); header.append(Self.hex(transferHash)!)
        header.append(contentsOf: HMAC<SHA256>.authenticationCode(for: header, using: secret))
        phase = "header"; peripheral.writeValue(header, for: write, type: .withResponse); armTimeout()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard busy else { return }
        guard error == nil else { fail("PC 수신 거부 · 연결 키와 저장 경로를 확인하세요."); return }
        if phase == "header" || phase == "commit" {
            guard let status else { return }; peripheral.readValue(for: status)
        } else if phase == "data" { offset += sent; progress = Double(offset) / Double(payload.count); sendNext() }
        armTimeout()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard busy, let secret, error == nil, let value = characteristic.value,
              let receipt = String(data: value, encoding: .utf8) else { fail("수신 확인 실패"); return }
        let parts = receipt.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == transferHash, let count = Int(parts[1]), count >= 0, count <= payload.count,
              let mac = Self.hex(parts[3]), HMAC<SHA256>.isValidAuthenticationCode(mac,
                authenticating: Data(parts.prefix(3).joined(separator: ":").utf8), using: secret) else { fail("PC 인증 실패 · 연결 키를 확인하세요."); return }
        if parts[2] == "saved", count == payload.count {
            busy = false; timeout?.cancel(); progress = 1; message = "PC 원본 보관 완료 · 위키 합성은 별도 검토"; central.cancelPeripheralConnection(peripheral)
        } else if phase == "header", parts[2] == "receiving" { offset = count; sendNext() }
        else { fail("PC 저장 확인 실패 · 다시 보내세요.") }
    }
    private func sendNext() {
        guard let peer, let write else { return }
        if offset == payload.count { phase = "commit"; peer.writeValue(Data([3]), for: write, type: .withResponse); return }
        phase = "data"
        sent = min(peer.maximumWriteValueLength(for: .withResponse) - 5, payload.count - offset)
        guard sent > 0 else { fail("BLE 전송 크기 오류"); return }
        var packet = Data([2]); packet.append(Self.number(offset)); packet.append(payload.subdata(in: offset..<(offset + sent)))
        peer.writeValue(packet, for: write, type: .withResponse); message = "전송 중 · \(Int(progress * 100))%"
    }
    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }; self?.fail("응답 시간 초과 · PC 수신기 확인 후 다시 시도하세요.")
        }
    }
    func cancel() { busy = false; timeout?.cancel(); central?.stopScan(); if let peer { central?.cancelPeripheralConnection(peer) }; write = nil; status = nil }
    private func fail(_ text: String) { cancel(); message = text }
    private static func number(_ n: Int) -> Data { var v = UInt32(n).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    private static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }; var data = Data(); var index = text.startIndex
        while index < text.endIndex { let end = text.index(index, offsetBy: 2); guard let b = UInt8(text[index..<end], radix: 16) else { return nil }; data.append(b); index = end }
        return data
    }
    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "TurboMeta.WikiBLE", kSecAttrAccount as String: "receiver"] }
    func savedKey() -> String {
        var query = keyQuery; query[kSecReturnData as String] = true
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    private func saveKey(_ data: Data) {
        SecItemDelete(keyQuery as CFDictionary); var query = keyQuery
        query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}

struct WikiBluetoothTransferView: View {
    let meeting: ArchivedMeeting
    @StateObject private var transfer = WikiBluetoothTransfer()
    @State private var key = ""
    var body: some View {
        Form {
            Section("PC 연결") {
                SecureField("PC 연결 키", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("PC 검색") { transfer.scan() }.disabled(transfer.busy)
                ForEach(transfer.devices, id: \.identifier) { device in
                    Button("\(device.name ?? "TurboMeta PC")로 보내기") { transfer.send(meeting, to: device, keyText: key) }
                        .disabled(transfer.busy || meeting.lines.isEmpty)
                }
            }
            Section { Text("선택한 전사·AI 분석·출처를 PC에 보관합니다. 음성은 보내지 않습니다. 앱을 열어 두세요."); Text(transfer.message)
                if transfer.busy { ProgressView(value: transfer.progress); Button("전송 취소") { transfer.cancel() } }
            }
        }.navigationTitle("위키로 보내기").onAppear { key = transfer.savedKey() }.onDisappear { transfer.cancel() }
    }
}

/*
 * 내 목소리 등록
 *
 * 문장 하나를 약 5초 읽어 착용자 목소리 견본을 만든다. 화자 구분 때 대화 앞에 붙여
 * 어느 목소리가 착용자인지 알아내는 데만 쓰며, 폰 안에만 저장한다.
 */

import AVFoundation
import SwiftUI

@MainActor
final class VoiceEnrollmentRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case saved
        case tooQuiet
        case failed
        case busy
    }

    static let sentence = "안녕하세요. 지금부터 대화를 시작하겠습니다. 오늘도 잘 부탁드립니다."

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var isEnrolled = VoiceEnrollmentStore.isEnrolled

    private let engine = AVAudioEngine()
    private let buffer = DiarizationAudioBuffer()
    private var task: Task<Void, Never>?

    func record() {
        guard phase != .recording else { return }
        guard !MeetingInterpreterViewModel.isConversationActive else {
            phase = .busy
            return
        }
        task?.cancel()
        task = Task { await run() }
    }

    func delete() {
        VoiceEnrollmentStore.delete()
        isEnrolled = false
        phase = .idle
    }

    func cancel() {
        task?.cancel()
        stopEngine()
    }

    private func run() async {
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard granted else {
            phase = .failed
            return
        }
        do {
            try configureSession()
            buffer.reset()
            let input = engine.inputNode
            let sink = buffer
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcm, _ in
                sink.append(pcm)
            }
            engine.prepare()
            try engine.start()
        } catch {
            DeveloperConsole.shared.log(.warning, category: "VoiceEnroll", "start failed code=\((error as NSError).code)")
            stopEngine()
            phase = .failed
            return
        }

        phase = .recording
        progress = 0
        let steps = 55
        for step in 1...steps {
            try? await Task.sleep(nanoseconds: UInt64(VoiceEnrollmentStore.recordDuration / Double(steps) * 1_000_000_000))
            if Task.isCancelled {
                stopEngine()
                phase = .idle
                return
            }
            progress = Double(step) / Double(steps)
        }
        stopEngine()

        let samples = buffer.drain()
        let speech = DiarizationAudio.speechSeconds(samples)
        DeveloperConsole.shared.log(.info, category: "VoiceEnroll", "recorded sec=\(samples.count / DiarizationAudio.sampleRate) speechSec=\(String(format: "%.1f", speech))")
        guard speech >= VoiceEnrollmentStore.minimumSpeechSeconds else {
            phase = .tooQuiet
            return
        }
        do {
            try VoiceEnrollmentStore.save(samples)
            isEnrolled = true
            phase = .saved
        } catch {
            DeveloperConsole.shared.log(.warning, category: "VoiceEnroll", "save failed code=\((error as NSError).code)")
            phase = .failed
        }
    }

    /// 회의와 같은 마이크 설정으로 녹음해야 목소리 특성이 비슷하게 잡힌다.
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        switch MeetingMicMode.current {
        case .phone:
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        case .headset:
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            if let bluetooth = session.availableInputs?.first(where: {
                $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
            }) {
                try? session.setPreferredInput(bluetooth)
            }
        }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

struct VoiceEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceEnrollmentRecorder()

    private var statusText: String? {
        switch recorder.phase {
        case .idle: return recorder.isEnrolled ? "voice.enroll.enrolled".localized : nil
        case .recording: return "voice.enroll.recording".localized
        case .saved: return "voice.enroll.saved".localized
        case .tooQuiet: return "voice.enroll.quiet".localized
        case .failed: return "voice.enroll.failed".localized
        case .busy: return "voice.enroll.busy".localized
        }
    }

    private var statusColor: Color {
        switch recorder.phase {
        case .saved: return .green
        case .tooQuiet, .failed, .busy: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 28) {
                Spacer()
                Text("voice.enroll.prompt".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(VoiceEnrollmentRecorder.sentence)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                ProgressView(value: recorder.progress)
                    .padding(.horizontal, 40)
                    .opacity(recorder.phase == .recording ? 1 : 0)

                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundColor(statusColor)
                }
                Spacer()

                Button {
                    recorder.record()
                } label: {
                    Label(
                        recorder.isEnrolled ? "voice.enroll.again".localized : "voice.enroll.record".localized,
                        systemImage: "mic.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.phase == .recording)
                .padding(.horizontal, 24)

                if recorder.isEnrolled, recorder.phase != .recording {
                    Button("voice.enroll.delete".localized, role: .destructive) {
                        recorder.delete()
                    }
                    .font(.footnote)
                }
            }
            .padding(.bottom, 24)
            .navigationTitle("voice.enroll.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close".localized) {
                        recorder.cancel()
                        dismiss()
                    }
                }
            }
        }
    }
}

/*
 * 화자 구분 서비스 (Gemini 3.5 Transcribe)
 *
 * 30초 대화 조각 앞에 착용자 목소리 견본을 붙여 한 파일로 보낸다.
 * Transcribe는 목소리별 이름표(spk_1, spk_2 …)를 요청마다 새로 붙이므로,
 * 견본 구간에 붙은 이름표를 "나"로 삼아 나머지를 "상대"로 나눈다.
 * 견본은 폰 안에만 저장하고 조각 분석 요청에만 함께 보낸다.
 */

import AVFoundation
import Foundation

/// 16kHz 모노 16비트 PCM: 화자 구분 요청과 목소리 견본의 공통 형식.
enum DiarizationAudio {
    static let sampleRate = 16_000
    /// 견본과 대화 사이에 넣는 무음 길이.
    static let enrollmentGap: TimeInterval = 0.6
    /// 조각에 말소리가 이보다 적으면 보내지 않는다.
    static let minimumSpeechSeconds: TimeInterval = 1.5

    static func wav(samples: [Int16], sampleRate: Int = DiarizationAudio.sampleRate) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        let little = samples.map { $0.littleEndian }
        little.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// 0.1초 단위로 말소리 수준(-45dBFS 이상) 구간을 센다.
    static func speechSeconds(_ samples: [Int16], sampleRate: Int = DiarizationAudio.sampleRate) -> TimeInterval {
        let frame = max(1, sampleRate / 10)
        var speechFrames = 0
        var index = 0
        while index + frame <= samples.count {
            var sum: Double = 0
            for sample in samples[index..<(index + frame)] {
                let value = Double(sample) / 32768
                sum += value * value
            }
            let meanSquare = sum / Double(frame)
            if meanSquare > 0, 10 * log10(meanSquare) >= Double(MeetingInputMeter.speechThresholdDb) {
                speechFrames += 1
            }
            index += frame
        }
        return Double(speechFrames) / 10
    }

    /// 견본 + 무음 + 대화 조각. 견본이 없으면 대화 조각만 돌려준다.
    static func composite(chunk: [Int16], enrollment: [Int16]?) -> (samples: [Int16], enrollmentEnd: TimeInterval?) {
        guard let enrollment, !enrollment.isEmpty else { return (chunk, nil) }
        let gap = [Int16](repeating: 0, count: Int(enrollmentGap * Double(sampleRate)))
        let end = Double(enrollment.count) / Double(sampleRate) + enrollmentGap / 2
        return (enrollment + gap + chunk, end)
    }
}

/// 입력 탭(오디오 스레드)에서 16kHz 모노 PCM으로 변환해 모으고 메인 스레드에서 꺼낸다.
final class DiarizationAudioBuffer {
    /// 처리가 밀려도 이 길이(90초)까지만 보관한다.
    static let maxSamples = DiarizationAudio.sampleRate * 90

    private let lock = NSLock()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(DiarizationAudio.sampleRate),
        channels: 1,
        interleaved: true
    )

    /// 오디오 스레드 한 곳에서만 호출한다.
    func append(_ buffer: AVAudioPCMBuffer) {
        let converted = convert(buffer)
        guard !converted.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: converted)
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        lock.unlock()
    }

    func drain() -> [Int16] {
        lock.lock()
        defer {
            samples.removeAll(keepingCapacity: true)
            lock.unlock()
        }
        return samples
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard buffer.frameLength > 0, let outputFormat else { return [] }
        if converterInputFormat == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// 착용자 목소리 견본(약 5초, 16kHz 모노 PCM). 폰 안에만 저장한다.
enum VoiceEnrollmentStore {
    static let recordDuration: TimeInterval = 5.5
    static let minimumSpeechSeconds: TimeInterval = 2.5

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceEnrollment", isDirectory: true)
            .appendingPathComponent("me.pcm")
    }

    static var isEnrolled: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func load() -> [Int16]? {
        guard let data = try? Data(contentsOf: fileURL), data.count >= 2 else { return nil }
        var samples = [Int16](repeating: 0, count: data.count / 2)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples.map { Int16(littleEndian: $0) }
    }

    static func save(_ samples: [Int16]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let little = samples.map { $0.littleEndian }
        let data = little.withUnsafeBytes { Data($0) }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum DiarizedRole: String, Equatable {
    case me
    case other
    /// 견본이 없거나 견본 구간 이름표를 찾지 못함.
    case unknown
}

struct DiarizedWord: Equatable {
    let text: String
    let speaker: String
    let start: TimeInterval
}

struct DiarizedTurn: Equatable {
    let role: DiarizedRole
    let speaker: String
    var text: String
    /// 대화 조각 시작 기준 초.
    let start: TimeInterval
}

enum DiarizationParser {
    /// Interactions 응답의 steps[].content[].annotations[] 중 word_info만 모은다.
    static func words(from object: [String: Any]) -> [DiarizedWord] {
        var words: [DiarizedWord] = []
        for step in object["steps"] as? [[String: Any]] ?? [] {
            for content in step["content"] as? [[String: Any]] ?? [] {
                for annotation in content["annotations"] as? [[String: Any]] ?? [] {
                    guard (annotation["type"] as? String) == "word_info",
                          let text = annotation["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    words.append(DiarizedWord(
                        text: text,
                        speaker: (annotation["speaker"] as? String) ?? "-",
                        start: offset(annotation["start_offset"]) ?? 0
                    ))
                }
            }
        }
        return words
    }

    /// "1.250s" 또는 숫자 형태의 시간값.
    static func offset(_ raw: Any?) -> TimeInterval? {
        if let number = raw as? NSNumber { return number.doubleValue }
        guard var text = raw as? String else { return nil }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("s") { text.removeLast() }
        return TimeInterval(text)
    }

    /// 견본 구간(enrollmentEnd 이전)에서 가장 많이 나온 이름표를 "나"로 정하고,
    /// 견본 단어는 버린 뒤 같은 화자의 연속 단어를 한 발언으로 묶는다.
    static func turns(words: [DiarizedWord], enrollmentEnd: TimeInterval?) -> [DiarizedTurn] {
        var meLabel: String?
        var conversation = words
        if let enrollmentEnd {
            let sample = words.filter { $0.start < enrollmentEnd }
            var counts: [String: Int] = [:]
            for word in sample where word.speaker != "-" { counts[word.speaker, default: 0] += 1 }
            if let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 {
                meLabel = best.key
            }
            conversation = words.filter { $0.start >= enrollmentEnd }
        }
        let origin = enrollmentEnd ?? 0

        var turns: [DiarizedTurn] = []
        for word in conversation {
            let role: DiarizedRole = meLabel == nil ? .unknown : (word.speaker == meLabel ? .me : .other)
            if var last = turns.last, last.speaker == word.speaker {
                last.text += " " + word.text
                turns[turns.count - 1] = last
            } else {
                turns.append(DiarizedTurn(role: role, speaker: word.speaker, text: word.text, start: max(0, word.start - origin)))
            }
        }
        return turns
    }
}

enum DiarizationError: Error, Equatable {
    case missingAPIKey
    case http(Int)
    case invalidResponse
    case timeout
}

final class SpeakerDiarizationService {
    static let model = "gemini-3.5-transcribe"
    /// Gemini 3.5 Transcribe 예상 요금(분당, 2026-09 가격표 기준).
    static let pricePerMinute = 0.005

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func requestBody(wavBase64: String) -> [String: Any] {
        [
            "model": model,
            "input": [[
                "type": "audio",
                "data": wavBase64,
                "mime_type": "audio/wav"
            ]],
            "generation_config": [
                "transcription_config": [
                    "language_codes": ["ko-KR"],
                    "mode": [
                        "type": "verbatim",
                        "diarization_mode": "speaker",
                        "timestamp_granularities": ["word"]
                    ]
                ]
            ]
        ]
    }

    func diarize(chunk: [Int16], enrollment: [Int16]?) async throws -> [DiarizedTurn] {
        let apiKey = VisionAPIConfig.apiKey
        guard !apiKey.isEmpty else { throw DiarizationError.missingAPIKey }
        guard let url = URL(string: "\(VisionAPIConfig.baseURL)/interactions") else {
            throw DiarizationError.invalidResponse
        }
        let composite = DiarizationAudio.composite(chunk: chunk, enrollment: enrollment)
        let wav = DiarizationAudio.wav(samples: composite.samples)
        let seconds = Double(composite.samples.count) / Double(DiarizationAudio.sampleRate)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in VisionAPIConfig.headers(with: apiKey) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(wavBase64: wav.base64EncodedString()))

        let startedAt = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        DeveloperConsole.shared.log(.info, category: "MeetingDiarize", "status=\(status) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) audioSec=\(Int(seconds)) enrolled=\(enrollment != nil)")
        guard (200...299).contains(status) else {
            if status == 429 {
                DeveloperConsole.shared.log(.warning, category: "MeetingDiarize", "quota \(MeetingGeminiService.quotaDiagnostic(from: data))")
            }
            throw DiarizationError.http(status)
        }
        GeminiUsageLedger.shared.recordAudio(lane: "diarize", seconds: seconds)

        var object = try Self.decode(data)
        object = try await waitUntilCompleted(object, apiKey: apiKey)
        let words = DiarizationParser.words(from: object)
        return DiarizationParser.turns(words: words, enrollmentEnd: composite.enrollmentEnd)
    }

    /// 응답이 아직 처리 중이면 완료될 때까지 짧게 조회한다.
    private func waitUntilCompleted(_ object: [String: Any], apiKey: String) async throws -> [String: Any] {
        var current = object
        var attempts = 0
        while let status = current["status"] as? String, status != "completed" {
            guard status != "failed", status != "cancelled",
                  let id = current["id"] as? String,
                  let url = URL(string: "\(VisionAPIConfig.baseURL)/\(id)") else {
                throw DiarizationError.invalidResponse
            }
            attempts += 1
            guard attempts <= 20 else { throw DiarizationError.timeout }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            var request = URLRequest(url: url)
            for (name, value) in VisionAPIConfig.headers(with: apiKey) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else { throw DiarizationError.http(code) }
            current = try Self.decode(data)
        }
        return current
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiarizationError.invalidResponse
        }
        return object
    }
}

/*
 * 시각 보조 인식 서비스
 *
 * 회의 중 안경 카메라 스트림을 유지하고 주기적으로 마지막 프레임을
 * Gemini로 분석해 (a) 인식률 보강용 용어 목록(contextualStrings)과
 * (b) 귓속말 설명의 장면 맥락을 제공한다. 오류는 조용히 무시한다.
 */

import SwiftUI
import UIKit

/// 설정의 화면 인식 단계. 이전 버전의 켜기/끄기 스위치(meeting.visualAssist)를 이어받는다.
enum MeetingSceneMode: String, CaseIterable, Identifiable {
    case standard
    case saver
    case off

    static let storageKey = "meeting.sceneMode"
    static let legacyToggleKey = "meeting.visualAssist"

    var id: String { rawValue }

    /// 화면 변화를 확인하는 간격. 끄기면 카메라 스트림도 켜지 않는다.
    var checkInterval: TimeInterval? {
        switch self {
        case .standard: return 20
        case .saver: return 60
        case .off: return nil
        }
    }

    var titleKey: String { "settings.scene.\(rawValue)" }
    var detailKey: String { "settings.scene.\(rawValue).detail" }

    static func resolve(stored: String?, legacyToggle: Bool?) -> MeetingSceneMode {
        if let stored, let mode = MeetingSceneMode(rawValue: stored) { return mode }
        if legacyToggle == false { return .off }
        return .standard
    }

    static var current: MeetingSceneMode {
        let defaults = UserDefaults.standard
        return resolve(
            stored: defaults.string(forKey: storageKey),
            legacyToggle: defaults.object(forKey: legacyToggleKey) as? Bool
        )
    }
}

@MainActor
final class VisualAssistService: ObservableObject {
    struct Context: Equatable {
        let terms: [String]
        let scene: String
    }

    /// 기본 단계의 확인 간격. 실제 간격은 설정 단계(baseInterval)를 따른다.
    nonisolated static let analysisInterval: TimeInterval = 20
    nonisolated static let maxInterval: TimeInterval = 120
    /// 429(쿼터 초과) 시 시각 보조를 잠시 완전히 멈춰 귓속말을 보호한다.
    static let quotaPauseInterval: TimeInterval = 300
    static let maxTerms = 30
    /// 화면이 그대로여도 이 시간이 지나면 한 번 다시 분석한다.
    static let refreshInterval: TimeInterval = 120
    /// 같은 화면 판정 기준(0~255 밝기 차이 평균). 실제 회의 로그의 diff 분포로 다시 정한다.
    nonisolated static let sceneChangeThreshold: Double = 12
    nonisolated static let sceneGridSize = 16
    /// 자동 장면 사진은 512px로 줄여 보내므로 중간 해상도(560토큰)로 충분하다.
    nonisolated static let sceneMediaResolution = "MEDIA_RESOLUTION_MEDIUM"

    var onContext: ((Context) -> Void)?
    var isUserRequestActive = false

    let baseInterval: TimeInterval
    private let streamViewModel: StreamSessionViewModel
    private let vision = VisionAPIService()
    private var loopTask: Task<Void, Never>?
    private(set) var isActive = false
    private var currentInterval: TimeInterval
    private var pausedUntil: Date?
    private var lastSignature: [UInt8]?
    private var lastAnalyzedAt = Date.distantPast

    init(streamViewModel: StreamSessionViewModel, baseInterval: TimeInterval = VisualAssistService.analysisInterval) {
        self.streamViewModel = streamViewModel
        self.baseInterval = baseInterval
        self.currentInterval = baseInterval
    }

    func start() {
        guard loopTask == nil else { return }
        isActive = true
        lastSignature = nil
        isUserRequestActive = false

        let streamViewModel = streamViewModel
        loopTask = Task { [weak self] in
            await streamViewModel.handleStartStreaming()
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64((self?.currentInterval ?? Self.analysisInterval) * 1_000_000_000)
                )
                guard let self, !Task.isCancelled else { break }
                await self.analyzeLatestFrame()
            }
        }
    }

    func stop() async {
        let task = loopTask
        task?.cancel()
        loopTask = nil
        isActive = false

        await task?.value
        await streamViewModel.stopSession()
    }

    private func analyzeLatestFrame() async {
        guard !isUserRequestActive else { return }
        if let pausedUntil, Date() < pausedUntil { return }
        guard let frame = streamViewModel.currentVideoFrame else { return }
        let signature = Self.signature(frame)
        if let signature, let lastSignature {
            let difference = Self.sceneDifference(lastSignature, signature)
            let stale = Date().timeIntervalSince(lastAnalyzedAt) >= Self.refreshInterval
            let changed = difference >= Self.sceneChangeThreshold
            DeveloperConsole.shared.log(
                .info,
                category: "MeetingScene",
                "diff=\(String(format: "%.1f", difference)) \(changed ? "changed" : (stale ? "refresh" : "skip"))"
            )
            if !changed && !stale { return }
        }
        let downscaled = Self.downscale(frame, maxDimension: 512)

        do {
            let raw = try await vision.analyzeImage(
                downscaled,
                prompt: Self.analysisPrompt,
                mediaResolution: Self.sceneMediaResolution,
                usageLane: "scene"
            )
            guard !Task.isCancelled, isActive else { return }
            if let context = Self.parseScene(raw) {
                lastSignature = signature
                lastAnalyzedAt = Date()
                currentInterval = baseInterval
                onContext?(context)
            }
        } catch {
            guard !Task.isCancelled, isActive else { return }
            handleAnalysisFailure(error)
        }
    }

    nonisolated static func sceneChanged(_ before: [UInt8], _ after: [UInt8]) -> Bool {
        sceneDifference(before, after) >= sceneChangeThreshold
    }

    /// 두 16×16 흑백 썸네일의 차이 점수(칸당 평균 밝기 차이, 0~255).
    /// 1) 상하좌우·대각선 1칸 이동(9가지) 각각에 대해 겹치는 칸만 비교하고
    /// 2) 겹치는 칸들의 평균 밝기를 각자 빼서 자동 노출·조명 변화를 무시한 뒤
    /// 3) 9가지 중 가장 작은 차이를 써서 고개의 미세한 움직임을 흡수한다.
    /// 평균을 화면 전체가 아니라 겹치는 칸 기준으로 빼야, 가장자리에 밝은 영역이
    /// 들어오거나 빠질 때 점수가 부풀지 않는다.
    /// 크기가 맞지 않으면 무한대(=바뀜)를 돌려준다.
    nonisolated static func sceneDifference(
        _ before: [UInt8],
        _ after: [UInt8],
        gridSize: Int = sceneGridSize
    ) -> Double {
        guard gridSize > 0, before.count == gridSize * gridSize, after.count == before.count else {
            return .infinity
        }
        var best = Double.infinity
        for dy in -1...1 {
            for dx in -1...1 {
                var pairs: [(previous: Double, current: Double)] = []
                pairs.reserveCapacity(gridSize * gridSize)
                for y in 0..<gridSize {
                    let shiftedY = y + dy
                    guard shiftedY >= 0, shiftedY < gridSize else { continue }
                    for x in 0..<gridSize {
                        let shiftedX = x + dx
                        guard shiftedX >= 0, shiftedX < gridSize else { continue }
                        pairs.append((
                            previous: Double(before[y * gridSize + x]),
                            current: Double(after[shiftedY * gridSize + shiftedX])
                        ))
                    }
                }
                guard !pairs.isEmpty else { continue }
                let count = Double(pairs.count)
                let meanBefore: Double = pairs.reduce(0.0) { $0 + $1.previous } / count
                let meanAfter: Double = pairs.reduce(0.0) { $0 + $1.current } / count
                var total = 0.0
                for pair in pairs {
                    total += abs((pair.current - meanAfter) - (pair.previous - meanBefore))
                }
                best = min(best, total / count)
            }
        }
        return best
    }

    private static func signature(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 256)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16,
                bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        return rendered ? pixels : nil
    }

    private func handleAnalysisFailure(_ error: Error) {
        if case QuickVisionError.apiError(let statusCode, _, _) = error,
           statusCode == 429 {
            pausedUntil = Date().addingTimeInterval(Self.quotaPauseInterval)
            currentInterval = baseInterval
            return
        }
        currentInterval = Self.nextInterval(current: currentInterval, hadFailure: true, base: baseInterval)
    }

    nonisolated static func nextInterval(
        current: TimeInterval,
        hadFailure: Bool,
        base: TimeInterval = analysisInterval
    ) -> TimeInterval {
        guard hadFailure else { return base }
        return min(current * 2, max(maxInterval, base))
    }

    nonisolated static func parseScene(_ raw: String) -> Context? {
        guard let data = jsonData(from: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scene = object["scene"] as? String else {
            return nil
        }

        let rawTerms = object["terms"] as? [String] ?? []
        let terms = rawTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "-" && $0 != "없음" && $0.count <= 60 }

        guard !scene.isEmpty || !terms.isEmpty else { return nil }
        return Context(terms: Array(terms.prefix(maxTerms)), scene: scene)
    }

    private nonisolated static func jsonData(from raw: String) -> Data? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.data(using: .utf8)
    }

    private nonisolated static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDimension, largest > 0 else { return image }
        let scale = maxDimension / largest
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static let analysisPrompt = """
    스마트 안경 앞쪽 카메라 프레임이다. 회의 통역 도우미가 인식률을 보강하려 한다.
    화면(슬라이드·문서·표지)에 보이는 고유명사·전문용어·숫자 지표명과 현재 장면을 요약하라.
    사람 얼굴 식별·인원 수·신체 묘사는 하지 않는다.
    출력은 JSON 하나만: {"terms": ["용어", ...], "scene": "한 문장 장면 요약"}
    terms는 최대 20개, scene은 40자 이내 한국어.
    """
}

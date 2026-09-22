/*
 * 시각 보조 인식 서비스
 *
 * 회의 중 안경 카메라 스트림을 유지하고 주기적으로 마지막 프레임을
 * Gemini로 분석해 (a) 인식률 보강용 용어 목록(contextualStrings)과
 * (b) 귓속말 설명의 장면 맥락을 제공한다. 오류는 조용히 무시한다.
 */

import SwiftUI
import UIKit

@MainActor
final class VisualAssistService: ObservableObject {
    struct Context: Equatable {
        let terms: [String]
        let scene: String
    }

    static let analysisInterval: TimeInterval = 5
    static let maxTerms = 30

    var onContext: ((Context) -> Void)?

    private let streamViewModel: StreamSessionViewModel
    private let vision = VisionAPIService()
    private var loopTask: Task<Void, Never>?
    private(set) var isActive = false

    init(streamViewModel: StreamSessionViewModel) {
        self.streamViewModel = streamViewModel
    }

    func start() {
        guard loopTask == nil else { return }
        isActive = true

        let streamViewModel = streamViewModel
        loopTask = Task { [weak self] in
            await streamViewModel.handleStartStreaming()
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.analysisInterval * 1_000_000_000)
                )
                guard let self, !Task.isCancelled else { break }
                self.analyzeLatestFrame()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isActive = false

        let streamViewModel = streamViewModel
        Task {
            await streamViewModel.stopSession()
        }
    }

    private func analyzeLatestFrame() {
        guard let frame = streamViewModel.currentVideoFrame else { return }
        let downscaled = Self.downscale(frame, maxDimension: 512)

        Task { [weak self] in
            do {
                let raw = try await vision.analyzeImage(
                    downscaled,
                    prompt: Self.analysisPrompt
                )
                if let context = Self.parseScene(raw) {
                    self?.onContext?(context)
                }
            } catch {
                // 시각 보조는 부가 기능이므로 회의를 방해하지 않는다.
            }
        }
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

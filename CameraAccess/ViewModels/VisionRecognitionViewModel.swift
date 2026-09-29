/*
 * 일반 이미지 인식 화면 상태
 */

import Foundation
import SwiftUI

@MainActor
final class VisionRecognitionViewModel: ObservableObject {
    @Published var isAnalyzing = false
    @Published var recognitionResult: String?
    @Published var errorMessage: String?
    @Published var customPrompt = "사진에 무엇이 있는지 한국어로 설명해 주세요."

    private let apiService: VisionAPIService
    private let photo: UIImage

    init(photo: UIImage, apiKey: String) {
        self.photo = photo
        self.apiService = VisionAPIService(apiKey: apiKey)
    }

    func analyzeImage(with prompt: String? = nil) async {
        guard !isAnalyzing else { return }

        isAnalyzing = true
        errorMessage = nil
        recognitionResult = nil

        let promptToUse = (prompt ?? customPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptToUse.isEmpty else {
            errorMessage = "질문 내용을 입력하세요"
            isAnalyzing = false
            return
        }

        print("[VisionVM][INFO] 분석 시작 promptLength=\(promptToUse.count)")
        do {
            recognitionResult = try await apiService.analyzeImage(photo, prompt: promptToUse)
            print("[VisionVM][INFO] 분석 성공 resultLength=\(recognitionResult?.count ?? 0)")
        } catch {
            let nsError = error as NSError
            errorMessage = error.localizedDescription
            print("[VisionVM][ERROR] 분석 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
        }

        isAnalyzing = false
    }

    func retryAnalysis() async {
        await analyzeImage()
    }

    func clearResult() {
        recognitionResult = nil
        errorMessage = nil
    }

    static let quickPrompts = [
        "사진에 무엇이 있는지 한국어로 설명해 주세요.",
        "장면을 자세히 설명해 주세요.",
        "사진 속 물체를 목록으로 정리해 주세요.",
        "이 장소가 어떤 곳인지 추정해 주세요.",
        "사진에서 읽을 수 있는 글자를 모두 알려 주세요.",
        "위험하거나 주의할 점이 있는지 확인해 주세요."
    ]
}

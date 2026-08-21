/*
 * 일반 AI 이미지 인식 서비스
 * QuickVisionService의 검증된 요청/오류/로그 경로를 재사용한다.
 */

import Foundation
import UIKit

struct VisionAPIService {
    private let quickVisionService: QuickVisionService

    init(apiKey: String, baseURL: String? = nil, model: String? = nil) {
        self.quickVisionService = QuickVisionService(
            apiKey: apiKey,
            baseURL: baseURL ?? VisionAPIConfig.baseURL,
            model: model ?? VisionAPIConfig.model
        )
    }

    init() {
        self.init(
            apiKey: VisionAPIConfig.apiKey,
            baseURL: VisionAPIConfig.baseURL,
            model: VisionAPIConfig.model
        )
    }

    func analyzeImage(
        _ image: UIImage,
        prompt: String = "사진의 핵심 내용을 자연스러운 한국어로 자세히 설명해 주세요."
    ) async throws -> String {
        print("[Vision][INFO] 일반 이미지 인식 시작 promptLength=\(prompt.count)")
        do {
            let result = try await quickVisionService.analyzeImage(image, customPrompt: prompt)
            print("[Vision][INFO] 일반 이미지 인식 완료 resultLength=\(result.count)")
            return result
        } catch {
            let nsError = error as NSError
            print("[Vision][ERROR] 일반 이미지 인식 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            throw error
        }
    }
}

enum VisionAPIError: LocalizedError {
    case invalidImage
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "이미지를 처리할 수 없습니다"
        case .emptyResponse:
            return "AI가 빈 응답을 반환했습니다"
        case .invalidResponse:
            return "AI 응답 형식이 올바르지 않습니다"
        case .apiError(let statusCode, let message):
            return "API 오류 \(statusCode): \(message)"
        }
    }
}

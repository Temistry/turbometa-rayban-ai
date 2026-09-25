/*
 * 음식 영양 분석 화면 상태
 */

import Foundation
import SwiftUI

@MainActor
final class LeanEatViewModel: ObservableObject {
    @Published var isAnalyzing = false
    @Published var nutritionData: FoodNutritionResponse?
    @Published var errorMessage: String?

    private let service: LeanEatService
    private let photo: UIImage

    init(photo: UIImage, apiKey: String) {
        self.photo = photo
        self.service = LeanEatService(apiKey: apiKey)
    }

    func analyzeFood() async {
        guard !isAnalyzing else { return }

        isAnalyzing = true
        errorMessage = nil
        nutritionData = nil
        print("[LeanEatVM][INFO] 음식 영양 분석 시작 imageSize=\(photo.size.width)x\(photo.size.height)")

        do {
            let result = try await service.analyzeFood(photo)
            nutritionData = result
            print("[LeanEatVM][INFO] 음식 영양 분석 완료 foodCount=\(result.foods.count) healthScore=\(result.healthScore)")
        } catch {
            let nsError = error as NSError
            errorMessage = error.localizedDescription
            print("[LeanEatVM][ERROR] 음식 영양 분석 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
        }

        isAnalyzing = false
    }

    func retry() async {
        await analyzeFood()
    }

    func clear() {
        nutritionData = nil
        errorMessage = nil
    }
}

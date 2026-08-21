/*
 * 음식 영양 분석 데이터 모델
 */

import Foundation

struct FoodNutritionResponse: Codable {
    let foods: [FoodItem]
    let totalCalories: Int
    let totalProtein: Double
    let totalFat: Double
    let totalCarbs: Double
    let healthScore: Int
    let suggestions: [String]

    enum CodingKeys: String, CodingKey {
        case foods
        case totalCalories = "total_calories"
        case totalProtein = "total_protein"
        case totalFat = "total_fat"
        case totalCarbs = "total_carbs"
        case healthScore = "health_score"
        case suggestions
    }
}

struct FoodItem: Codable, Identifiable {
    let id = UUID()
    let name: String
    let portion: String
    let calories: Int
    let protein: Double
    let fat: Double
    let carbs: Double
    let fiber: Double?
    let sugar: Double?
    let healthRating: String

    enum CodingKeys: String, CodingKey {
        case name
        case portion
        case calories
        case protein
        case fat
        case carbs
        case fiber
        case sugar
        case healthRating = "health_rating"
    }

    /// 이전 중국어 응답과 새 한국어 응답을 모두 한국어 UI 값으로 정규화한다.
    var localizedHealthRating: String {
        switch healthRating.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "매우 좋음", "优秀", "excellent", "Excellent":
            return "매우 좋음"
        case "좋음", "良好", "good", "Good":
            return "좋음"
        case "보통", "一般", "fair", "Fair":
            return "보통"
        case "주의", "较差", "poor", "Poor":
            return "주의"
        default:
            return healthRating.isEmpty ? "평가 없음" : healthRating
        }
    }

    var healthRatingSymbol: String {
        switch localizedHealthRating {
        case "매우 좋음": return "●"
        case "좋음": return "●"
        case "보통": return "●"
        case "주의": return "●"
        default: return "○"
        }
    }

    var healthRatingColorName: String {
        switch localizedHealthRating {
        case "매우 좋음": return "green"
        case "좋음": return "yellow"
        case "보통": return "orange"
        case "주의": return "red"
        default: return "gray"
        }
    }
}

extension FoodNutritionResponse {
    var formattedTotalCalories: String {
        "\(totalCalories) kcal"
    }

    var formattedTotalProtein: String {
        String(format: "%.1f g", totalProtein)
    }

    var formattedTotalFat: String {
        String(format: "%.1f g", totalFat)
    }

    var formattedTotalCarbs: String {
        String(format: "%.1f g", totalCarbs)
    }

    var healthScoreColor: String {
        switch healthScore {
        case 80...: return "green"
        case 60...: return "yellow"
        case 40...: return "orange"
        default: return "red"
        }
    }

    var healthScoreText: String {
        switch healthScore {
        case 80...: return "매우 건강함"
        case 60...: return "건강한 편"
        case 40...: return "보통"
        default: return "개선 필요"
        }
    }
}

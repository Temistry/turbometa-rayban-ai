/*
 * 음식 영양 분석 화면
 */

import SwiftUI

struct LeanEatView: View {
    @StateObject private var viewModel: LeanEatViewModel
    @Environment(\.dismiss) private var dismiss

    let photo: UIImage

    init(photo: UIImage, apiKey: String) {
        self.photo = photo
        self._viewModel = StateObject(wrappedValue: LeanEatViewModel(photo: photo, apiKey: apiKey))
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.secondaryBackground.ignoresSafeArea()

                VStack(spacing: AppSpacing.md) {
                    ScrollView {
                        VStack(spacing: AppSpacing.lg) {
                            photoSection

                            if viewModel.isAnalyzing {
                                analyzingView
                            } else if let error = viewModel.errorMessage {
                                errorView(error)
                            } else if let nutrition = viewModel.nutritionData {
                                nutritionResultView(nutrition)
                            } else {
                                analyzePromptView
                            }
                        }
                        .padding()
                    }

                    Button("분석 닫기") {
                        dismiss()
                    }
                    .font(AppTypography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColors.secondaryBackground)
                    .foregroundColor(AppColors.textPrimary)
                }
            }
            .navigationTitle("leaneat.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
        .task {
            if viewModel.nutritionData == nil && viewModel.errorMessage == nil {
                await viewModel.analyzeFood()
            }
        }
    }

    private var photoSection: some View {
        Image(uiImage: photo)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 250)
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 8, x: 0, y: 4)
    }

    private var analyzingView: some View {
        VStack(spacing: AppSpacing.lg) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(AppColors.leanEat)

            Text("음식과 영양 정보를 분석하고 있습니다")
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)

            Text("사진을 AI 서비스로 전송하므로 몇 초 정도 걸릴 수 있습니다")
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, AppSpacing.xl)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("leaneat.error.title".localized)
                .font(AppTypography.title2)
                .foregroundColor(AppColors.textPrimary)

            Text(error)
                .font(AppTypography.body)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal)

            Button {
                Task { await viewModel.retry() }
            } label: {
                Label("leaneat.retry".localized, systemImage: "arrow.clockwise")
                    .font(AppTypography.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColors.leanEat)
                    .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.xl)
        }
        .padding(.vertical, AppSpacing.xl)
    }

    private var analyzePromptView: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "chart.bar.doc.horizontal.fill")
                .font(.system(size: 60))
                .foregroundColor(AppColors.leanEat)

            Text("영양 분석 시작")
                .font(AppTypography.title2)
                .foregroundColor(AppColors.textPrimary)

            Text("아래 버튼을 눌러 사진 속 음식의 예상 영양 정보를 분석합니다")
                .font(AppTypography.body)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.analyzeFood() }
            } label: {
                Label("분석 시작", systemImage: "sparkles")
                    .font(AppTypography.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(
                        LinearGradient(
                            colors: [AppColors.leanEat, AppColors.leanEat.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.xl)
        }
        .padding(.vertical, AppSpacing.xl)
    }

    private func nutritionResultView(_ nutrition: FoodNutritionResponse) -> some View {
        VStack(spacing: AppSpacing.lg) {
            healthScoreCard(nutrition)
            totalNutritionCard(nutrition)
            foodItemsList(nutrition.foods)

            if !nutrition.suggestions.isEmpty {
                suggestionsCard(nutrition.suggestions)
            }

            Text("수치는 사진을 바탕으로 한 AI 추정치이며 의료 또는 영양 진단이 아닙니다")
                .font(.caption2)
                .foregroundColor(AppColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func healthScoreCard(_ nutrition: FoodNutritionResponse) -> some View {
        let scoreColor = color(named: nutrition.healthScoreColor)

        return VStack(spacing: AppSpacing.md) {
            Text("leaneat.healthscore".localized)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 15)
                    .frame(width: 140, height: 140)

                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, nutrition.healthScore))) / 100)
                    .stroke(
                        LinearGradient(
                            colors: [scoreColor, scoreColor.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 15, lineCap: .round)
                    )
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text("\(nutrition.healthScore)")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)

                    Text(nutrition.healthScoreText)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            }
        }
        .padding()
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.xl)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }

    private func totalNutritionCard(_ nutrition: FoodNutritionResponse) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("leaneat.totalnutrition".localized)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: AppSpacing.md
            ) {
                nutritionItem(
                    icon: "flame.fill",
                    title: "leaneat.calories".localized,
                    value: nutrition.formattedTotalCalories,
                    color: .orange
                )
                nutritionItem(
                    icon: "leaf.fill",
                    title: "leaneat.protein".localized,
                    value: nutrition.formattedTotalProtein,
                    color: .green
                )
                nutritionItem(
                    icon: "drop.fill",
                    title: "leaneat.fat".localized,
                    value: nutrition.formattedTotalFat,
                    color: .yellow
                )
                nutritionItem(
                    icon: "sparkles",
                    title: "leaneat.carbs".localized,
                    value: nutrition.formattedTotalCarbs,
                    color: .blue
                )
            }
        }
        .padding()
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.xl)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }

    private func nutritionItem(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            Text(title)
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)

            Text(value)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppColors.secondaryBackground)
        .cornerRadius(AppCornerRadius.lg)
    }

    private func foodItemsList(_ foods: [FoodItem]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("leaneat.foods".localized)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)
                .padding(.horizontal)

            ForEach(foods) { food in
                foodItemCard(food)
            }
        }
    }

    private func foodItemCard(_ food: FoodItem) -> some View {
        let ratingColor = color(named: food.healthRatingColorName)

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(food.healthRatingSymbol)
                    .font(.title2)
                    .foregroundColor(ratingColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(food.name)
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)

                    Text(food.portion)
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textSecondary)
                }

                Spacer()

                Text(food.localizedHealthRating)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 4)
                    .background(ratingColor)
                    .cornerRadius(AppCornerRadius.sm)
            }

            Divider()

            HStack(spacing: AppSpacing.lg) {
                miniNutritionItem(icon: "flame.fill", value: "\(food.calories)", unit: "kcal", color: .orange)
                miniNutritionItem(icon: "leaf.fill", value: String(format: "%.1f", food.protein), unit: "g", color: .green)
                miniNutritionItem(icon: "drop.fill", value: String(format: "%.1f", food.fat), unit: "g", color: .yellow)
                miniNutritionItem(icon: "sparkles", value: String(format: "%.1f", food.carbs), unit: "g", color: .blue)
            }
        }
        .padding()
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }

    private func miniNutritionItem(icon: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)

            HStack(spacing: 2) {
                Text(value).font(.system(size: 14, weight: .semibold))
                Text(unit).font(.system(size: 10))
            }
            .foregroundColor(AppColors.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestionsCard(_ suggestions: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Label("leaneat.suggestions".localized, systemImage: "lightbulb.fill")
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)

            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Text("\(index + 1).")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.leanEat)
                        .fontWeight(.bold)

                    Text(suggestion)
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .background(AppColors.leanEat.opacity(0.1))
        .cornerRadius(AppCornerRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.lg)
                .stroke(AppColors.leanEat.opacity(0.3), lineWidth: 1)
        )
    }

    private func color(named name: String) -> Color {
        switch name {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        default: return .gray
        }
    }
}

/*
 * 기능별 기록 화면
 */

import SwiftUI

struct RecordsView: View {
    @State private var selectedTab = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.lg) {
                        RecordTabButton(title: "영양 분석", isSelected: selectedTab == 0) { selectedTab = 0 }
                        RecordTabButton(title: "단어 학습", isSelected: selectedTab == 1) { selectedTab = 1 }
                        RecordTabButton(title: "quickvision.tab".localized, isSelected: selectedTab == 2) { selectedTab = 2 }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.md)
                }
                .background(AppColors.tertiaryBackground)

                TabView(selection: $selectedTab) {
                    LeanEatRecordsView().tag(0)
                    WordLearnRecordsView().tag(1)
                    QuickVisionRecordsView().tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("records.title".localized)
        }
    }
}

struct RecordTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.sm) {
                Text(title)
                    .font(AppTypography.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? AppColors.primary : AppColors.textSecondary)

                Rectangle()
                    .fill(isSelected
                          ? AnyShapeStyle(LinearGradient(
                            colors: [AppColors.primary, AppColors.secondary],
                            startPoint: .leading,
                            endPoint: .trailing
                          ))
                          : AnyShapeStyle(Color.clear))
                    .frame(height: 3)
                    .cornerRadius(1.5)
            }
        }
    }
}

// MARK: - Available record tabs

struct LeanEatRecordsView: View {
    var body: some View {
        EmptyRecordView(
            icon: "chart.bar.fill",
            color: AppColors.leanEat,
            title: "영양 분석 기록이 없습니다",
            description: "영양 분석 기록 저장 기능은 준비 중입니다"
        )
        .background(AppColors.secondaryBackground)
    }
}

struct WordLearnRecordsView: View {
    var body: some View {
        EmptyRecordView(
            icon: "book.closed.fill",
            color: AppColors.wordLearn,
            title: "단어 학습 기록이 없습니다",
            description: "단어 학습 기능은 준비 중입니다"
        )
        .background(AppColors.secondaryBackground)
    }
}

private struct EmptyRecordView: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        ZStack {
            AppColors.secondaryBackground.ignoresSafeArea()
            VStack(spacing: AppSpacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 64))
                    .foregroundColor(color.opacity(0.6))
                Text(title)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)
            }
        }
    }
}

// MARK: - Quick Vision

struct QuickVisionRecordsView: View {
    @State private var records: [QuickVisionRecord] = []
    @State private var selectedRecord: QuickVisionRecord?

    var body: some View {
        ZStack {
            AppColors.secondaryBackground.ignoresSafeArea()

            if records.isEmpty {
                EmptyRecordView(
                    icon: "eye.circle",
                    color: AppColors.quickVision,
                    title: "quickvision.records.empty".localized,
                    description: "quickvision.records.empty.hint".localized
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(records) { record in
                            QuickVisionRecordCell(record: record)
                                .onTapGesture { selectedRecord = record }
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .refreshable { loadRecords() }
            }
        }
        .onAppear { loadRecords() }
        .sheet(item: $selectedRecord) { record in
            QuickVisionRecordDetailView(record: record)
        }
    }

    private func loadRecords() {
        records = QuickVisionStorage.shared.loadAllRecords()
        print("[Records][INFO] 퀵비전 기록 \(records.count)개 로드")
    }
}

struct QuickVisionRecordCell: View {
    let record: QuickVisionRecord

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            if let thumbnail = record.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
            } else {
                RoundedRectangle(cornerRadius: AppCornerRadius.md)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 70, height: 70)
                    .overlay {
                        Image(systemName: "photo").foregroundColor(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    Image(systemName: record.mode.icon)
                        .foregroundColor(AppColors.quickVision)
                        .font(AppTypography.subheadline)
                    Text(record.mode.displayName)
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    QuickVisionRecordStatusLabel(status: record.status)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textTertiary)
                }

                Text(record.summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)

                Label(record.formattedDate, systemImage: "clock")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }
}

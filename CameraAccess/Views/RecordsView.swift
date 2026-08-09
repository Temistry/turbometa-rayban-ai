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
                        RecordTabButton(title: "Live AI", isSelected: selectedTab == 0) { selectedTab = 0 }
                        RecordTabButton(title: "실시간 번역", isSelected: selectedTab == 1) { selectedTab = 1 }
                        RecordTabButton(title: "영양 분석", isSelected: selectedTab == 2) { selectedTab = 2 }
                        RecordTabButton(title: "단어 학습", isSelected: selectedTab == 3) { selectedTab = 3 }
                        RecordTabButton(title: "quickvision.tab".localized, isSelected: selectedTab == 4) { selectedTab = 4 }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.md)
                }
                .background(AppColors.tertiaryBackground)

                TabView(selection: $selectedTab) {
                    LiveAIRecordsView().tag(0)
                    TranslationRecordsView().tag(1)
                    LeanEatRecordsView().tag(2)
                    WordLearnRecordsView().tag(3)
                    QuickVisionRecordsView().tag(4)
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

// MARK: - Live AI

struct LiveAIRecordsView: View {
    @StateObject private var viewModel = ConversationListViewModel()
    @State private var selectedConversation: ConversationRecord?
    @State private var showDetail = false

    var body: some View {
        ZStack {
            AppColors.secondaryBackground.ignoresSafeArea()

            if viewModel.conversations.isEmpty {
                EmptyRecordView(
                    icon: "brain.head.profile",
                    color: AppColors.liveAI,
                    title: "Live AI 대화 기록이 없습니다",
                    description: "Live AI를 사용하면 대화 기록이 여기에 표시됩니다"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(viewModel.conversations) { conversation in
                            ConversationCell(conversation: conversation)
                                .onTapGesture {
                                    selectedConversation = conversation
                                    showDetail = true
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteConversation(conversation.id)
                                    } label: {
                                        Label("삭제", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .refreshable { viewModel.loadConversations() }
            }
        }
        .onAppear { viewModel.loadConversations() }
        .sheet(isPresented: $showDetail) {
            if let selectedConversation {
                ConversationDetailView(conversation: selectedConversation)
            }
        }
    }
}

@MainActor
final class ConversationListViewModel: ObservableObject {
    @Published var conversations: [ConversationRecord] = []

    func loadConversations() {
        conversations = ConversationStorage.shared.loadAllConversations()
        print("[Records][INFO] Live AI 대화 \(conversations.count)개 로드")
    }

    func deleteConversation(_ id: UUID) {
        ConversationStorage.shared.deleteConversation(id)
        print("[Records][INFO] Live AI 대화 삭제 id=\(id)")
        loadConversations()
    }
}

struct ConversationCell: View {
    let conversation: ConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(AppColors.liveAI)
                    .font(AppTypography.headline)

                Text(conversation.title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer()
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            if !conversation.summary.isEmpty {
                Text(conversation.summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: AppSpacing.md) {
                Label(conversation.formattedDate, systemImage: "clock")
                Label("메시지 \(conversation.messageCount)개", systemImage: "bubble.left.and.bubble.right")
                Spacer()
            }
            .font(AppTypography.caption)
            .foregroundColor(AppColors.textSecondary)
        }
        .padding(AppSpacing.md)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Placeholder record tabs

struct TranslationRecordsView: View {
    var body: some View {
        EmptyRecordView(
            icon: "text.bubble",
            color: AppColors.translate,
            title: "번역 기록이 없습니다",
            description: "번역 기록 저장 기능은 준비 중입니다"
        )
        .background(AppColors.secondaryBackground)
    }
}

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

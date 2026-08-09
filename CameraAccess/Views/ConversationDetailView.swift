/*
 * Live AI 대화 상세 화면
 */

import SwiftUI

struct ConversationDetailView: View {
    let conversation: ConversationRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                AppColors.secondaryBackground.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(conversation.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("대화 상세")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Label(conversation.formattedDate, systemImage: "clock")
                    Spacer()
                    Label("메시지 \(conversation.messageCount)개", systemImage: "bubble.left.and.bubble.right")
                }
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
                .padding(AppSpacing.md)
                .background(AppColors.tertiaryBackground.opacity(0.95))
            }
        }
    }
}

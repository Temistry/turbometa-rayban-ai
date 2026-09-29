/*
 * 앱 시작 시 필요한 권한 안내 화면
 */

import SwiftUI

struct PermissionsRequestView: View {
    @StateObject private var permissionsManager = PermissionsManager.shared
    @State private var isRequesting = false
    @State private var showSettings = false
    let onComplete: (Bool) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.primary.opacity(0.1), AppColors.secondary.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: AppSpacing.xl) {
                Spacer()

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 80))
                    .foregroundColor(AppColors.primary)

                VStack(spacing: AppSpacing.sm) {
                    Text("권한이 필요합니다")
                        .font(AppTypography.title)
                        .foregroundColor(AppColors.textPrimary)

                    Text("TurboMeta의 음성 대화와 사진 저장 기능에 필요한 권한입니다")
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                }

                VStack(spacing: AppSpacing.md) {
                    PermissionRow(
                        icon: "mic.fill",
                        title: "마이크",
                        description: "실시간 음성 대화와 번역"
                    )

                    PermissionRow(
                        icon: "photo.fill",
                        title: "사진 추가",
                        description: "안경으로 촬영한 사진 저장"
                    )
                }
                .padding(.horizontal, AppSpacing.xl)

                Spacer()

                VStack(spacing: AppSpacing.md) {
                    if isRequesting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(1.5)
                    } else if showSettings {
                        VStack(spacing: AppSpacing.sm) {
                            Text("일부 권한이 허용되지 않았습니다")
                                .font(AppTypography.caption)
                                .foregroundColor(.red)

                            Button {
                                permissionsManager.openSettings()
                            } label: {
                                HStack {
                                    Image(systemName: "gear")
                                    Text("iPhone 설정 열기")
                                        .font(AppTypography.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.md)
                                .background(AppColors.primary)
                                .foregroundColor(.white)
                                .cornerRadius(AppCornerRadius.lg)
                            }

                            Button("제한된 기능으로 계속") {
                                print("[Permission][WARN] 일부 권한 없이 계속 진행")
                                onComplete(false)
                            }
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textSecondary)
                        }
                    } else {
                        Button {
                            requestPermissions()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("권한 요청")
                                    .font(AppTypography.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.md)
                            .background(AppColors.primary)
                            .foregroundColor(.white)
                            .cornerRadius(AppCornerRadius.lg)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.xl)
                .padding(.bottom, AppSpacing.xl)
            }
        }
        .onAppear {
            if permissionsManager.checkAllPermissions() {
                print("[Permission][INFO] 필수 권한이 이미 허용됨")
                onComplete(true)
            }
        }
    }

    private func requestPermissions() {
        isRequesting = true
        print("[Permission][INFO] 마이크 및 사진 추가 권한 요청 시작")

        permissionsManager.requestAllPermissions { allGranted in
            isRequesting = false
            print("[Permission][INFO] 권한 요청 종료 allGranted=\(allGranted)")

            if allGranted {
                onComplete(true)
            } else {
                showSettings = true
            }
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(AppColors.primary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)

                Text(description)
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
            }

            Spacer()
        }
        .padding(AppSpacing.md)
        .background(Color.white)
        .cornerRadius(AppCornerRadius.md)
        .shadow(color: AppShadow.small(), radius: 5, x: 0, y: 2)
    }
}

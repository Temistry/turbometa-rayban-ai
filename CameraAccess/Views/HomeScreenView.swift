/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  @ObservedObject var viewModel: WearablesViewModel
  @State private var showConnectionSuccess = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          AppColors.primary.opacity(0.15),
          AppColors.secondary.opacity(0.15),
          Color.white
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .edgesIgnoringSafeArea(.all)

      VStack(spacing: AppSpacing.xl) {
        Spacer()

        VStack(spacing: AppSpacing.md) {
          Image(.cameraAccessIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 100)
            .shadow(color: AppShadow.medium(), radius: 10, x: 0, y: 5)

          Text("TurboMeta")
            .font(AppTypography.largeTitle)
            .foregroundColor(AppColors.textPrimary)

          Text("Ray-Ban Meta 도우미")
            .font(AppTypography.callout)
            .foregroundColor(AppColors.textSecondary)
        }

        VStack(spacing: AppSpacing.md) {
          FeatureTipView(
            icon: "video.fill",
            title: "안경 시점 영상",
            text: "안경으로 보고 있는 장면을 실시간으로 확인하고 촬영합니다"
          )
          FeatureTipView(
            icon: "brain.head.profile",
            title: "한국어 AI 대화",
            text: "눈앞의 장면을 바탕으로 한국어 음성과 텍스트로 도움을 받습니다"
          )
          FeatureTipView(
            icon: "waveform",
            title: "음성 명령",
            text: "Siri와 단축어를 이용해 퀵비전과 실시간 대화를 실행합니다"
          )
        }

        Spacer()

        VStack(spacing: AppSpacing.md) {
          Text("Meta AI 앱으로 이동해 안경 연결을 승인합니다")
            .font(AppTypography.footnote)
            .foregroundColor(AppColors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.lg)

          Button {
            print("[Registration][INFO] Ray-Ban Meta 연결 요청")
            viewModel.connectGlasses()
          } label: {
            HStack(spacing: AppSpacing.sm) {
              if viewModel.registrationState == .registering {
                ProgressView()
                  .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("연결 중...")
              } else {
                Image(systemName: "eye.circle.fill")
                  .font(.title3)
                Text("Ray-Ban Meta 연결")
              }
            }
            .font(AppTypography.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(
              LinearGradient(
                colors: [AppColors.primary, AppColors.secondary],
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .cornerRadius(AppCornerRadius.lg)
            .shadow(color: AppShadow.medium(), radius: 8, x: 0, y: 4)
          }
          .disabled(viewModel.registrationState == .registering)
          .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.bottom, AppSpacing.xl)
      }
      .padding(.vertical, AppSpacing.xl)

      if showConnectionSuccess {
        VStack {
          Spacer()

          HStack(spacing: AppSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
              .font(.title2)
              .foregroundColor(.green)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
              Text("연결 완료")
                .font(AppTypography.headline)
                .foregroundColor(.white)
              Text("TurboMeta를 시작합니다...")
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.9))
            }

            Spacer()
          }
          .padding(AppSpacing.md)
          .background(Color.black.opacity(0.85))
          .cornerRadius(AppCornerRadius.lg)
          .shadow(color: AppShadow.large(), radius: 15, x: 0, y: 8)
          .padding(AppSpacing.lg)
          .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
    }
    .onChange(of: viewModel.registrationState) { _, newState in
      print("[Registration][INFO] 등록 상태 변경 state=\(newState)")
      if newState == .registered {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
          showConnectionSuccess = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          withAnimation {
            showConnectionSuccess = false
          }
        }
      }
    }
  }
}

struct FeatureTipView: View {
  let icon: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: AppSpacing.md) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [AppColors.primary.opacity(0.2), AppColors.secondary.opacity(0.2)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .frame(width: 48, height: 48)

        Image(systemName: icon)
          .font(.title3)
          .foregroundColor(AppColors.primary)
      }

      VStack(alignment: .leading, spacing: AppSpacing.xs) {
        Text(title)
          .font(AppTypography.headline)
          .foregroundColor(AppColors.textPrimary)

        Text(text)
          .font(AppTypography.subheadline)
          .foregroundColor(AppColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()
    }
    .padding(.horizontal, AppSpacing.lg)
  }
}

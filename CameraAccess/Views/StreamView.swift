/*
 * Meta 안경 영상 스트림 및 촬영 화면
 */

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      if !viewModel.hasActiveDevice {
        deviceNotConnectedView
      } else {
        if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
          GeometryReader { geometry in
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()
          }
          .edgesIgnoringSafeArea(.all)
        } else {
          VStack(spacing: 12) {
            ProgressView()
              .scaleEffect(1.5)
              .tint(.white)
            Text("stream.waiting".localized)
              .foregroundColor(.white.opacity(0.8))
          }
        }

        VStack {
          Spacer()
          ControlsView(viewModel: viewModel)
        }
        .padding(24)

        VStack {
          Spacer()
          if viewModel.activeTimeLimit.isTimeLimited && viewModel.remainingTime > 0 {
            Text("stream.ending".localized(viewModel.remainingTime.formattedCountdown))
              .font(.system(size: 15))
              .foregroundColor(.white)
              .padding(.bottom, 96)
          }
        }
      }
    }
    .onAppear {
      guard viewModel.hasActiveDevice else {
        print("[StreamView][WARN] 활성 안경이 없어 스트림 시작 생략")
        return
      }

      Task {
        print("[StreamView][INFO] 영상 스트림 자동 시작 요청")
        await viewModel.handleStartStreaming()
      }
    }
    .onDisappear {
      Task {
        print("[StreamView][INFO] 화면 종료 정리 시작 status=\(viewModel.streamingStatus)")
        await viewModel.cleanup()
      }
    }
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          },
          onAIRecognition: {
            viewModel.showPhotoPreview = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
              viewModel.showVisionRecognition = true
            }
          },
          onLeanEat: {
            viewModel.showPhotoPreview = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
              viewModel.showLeanEat = true
            }
          }
        )
      }
    }
    .sheet(isPresented: $viewModel.showVisionRecognition) {
      if let photo = viewModel.capturedPhoto {
        VisionRecognitionView(photo: photo, apiKey: VisionAPIConfig.apiKey)
      }
    }
    .sheet(isPresented: $viewModel.showLeanEat) {
      if let photo = viewModel.capturedPhoto {
        LeanEatView(photo: photo, apiKey: VisionAPIConfig.apiKey)
      }
    }
    .fullScreenCover(isPresented: $viewModel.showOmniRealtime) {
      OmniRealtimeView(streamViewModel: viewModel, apiKey: VisionAPIConfig.apiKey)
    }
  }

  private var deviceNotConnectedView: some View {
    VStack(spacing: AppSpacing.xl) {
      Spacer()

      VStack(spacing: AppSpacing.lg) {
        Image(systemName: "eyeglasses")
          .font(.system(size: 80))
          .foregroundColor(.white.opacity(0.6))

        Text("stream.device.notconnected.title".localized)
          .font(AppTypography.title2)
          .foregroundColor(.white)

        Text("stream.device.notconnected.message".localized)
          .font(AppTypography.body)
          .foregroundColor(.white.opacity(0.8))
          .multilineTextAlignment(.center)
          .padding(.horizontal, AppSpacing.xl)
      }

      Spacer()

      Button {
        dismiss()
      } label: {
        Label("stream.device.backtohome".localized, systemImage: "chevron.left")
          .font(AppTypography.headline)
          .frame(maxWidth: .infinity)
          .padding(.vertical, AppSpacing.md)
          .background(.white)
          .foregroundColor(.black)
          .cornerRadius(AppCornerRadius.lg)
      }
      .padding(.horizontal, AppSpacing.xl)
      .padding(.bottom, AppSpacing.xl)
    }
  }
}

struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel

  var body: some View {
    HStack(spacing: 8) {
      CustomButton(
        title: "stream.stop".localized,
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          print("[StreamView][INFO] 사용자가 스트림 중지 요청")
          await viewModel.stopSession()
        }
      }

      CircleButton(
        icon: "timer",
        text: viewModel.activeTimeLimit != .noLimit ? viewModel.activeTimeLimit.displayText : nil
      ) {
        let nextTimeLimit = viewModel.activeTimeLimit.next
        print("[StreamView][INFO] 시간 제한 변경 next=\(nextTimeLimit)")
        viewModel.setTimeLimit(nextTimeLimit)
      }

      CircleButton(icon: "camera.fill", text: nil) {
        print("[StreamView][INFO] 사진 촬영 요청")
        viewModel.capturePhoto()
      }

      CircleButton(icon: "brain.head.profile", text: nil) {
        print("[StreamView][INFO] 실시간 AI 화면 열기")
        viewModel.showOmniRealtime = true
      }
    }
  }
}

/*
 * 영상 스트림 시작 전 안내 화면
 */

import MWDATCore
import SwiftUI

struct NonStreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @State private var sheetHeight: CGFloat = 300

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      VStack {
        HStack {
          Spacer()
          Menu {
            Button("안경 연결 해제", role: .destructive) {
              print("[NonStream][INFO] 사용자가 안경 연결 해제 요청")
              wearablesVM.disconnectGlasses()
            }
            .disabled(wearablesVM.registrationState != .registered)
          } label: {
            Image(systemName: "gearshape")
              .resizable()
              .aspectRatio(contentMode: .fit)
              .foregroundColor(.white)
              .frame(width: 24, height: 24)
          }
          .accessibilityLabel("안경 설정")
        }

        Spacer()

        VStack(spacing: 12) {
          Image(.cameraAccessIcon)
            .resizable()
            .renderingMode(.template)
            .foregroundColor(.white)
            .aspectRatio(contentMode: .fit)
            .frame(width: 120)

          Text("안경 카메라 스트림")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)

          Text("스트림 시작 버튼을 누르면 Ray-Ban Meta 안경이 보고 있는 영상을 표시합니다. 카메라 버튼으로 사진도 촬영할 수 있습니다.")
            .font(.system(size: 15))
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
        }
        .padding(.horizontal, 12)

        Spacer()

        HStack(spacing: 8) {
          Image(systemName: "hourglass")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.white.opacity(0.7))
            .frame(width: 16, height: 16)

          Text("활성 안경을 기다리는 중")
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.7))
        }
        .padding(.bottom, 12)
        .opacity(viewModel.hasActiveDevice ? 0 : 1)

        CustomButton(
          title: "스트림 시작",
          style: .primary,
          isDisabled: !viewModel.hasActiveDevice
        ) {
          Task {
            print("[NonStream][INFO] 사용자가 영상 스트림 시작 요청 hasDevice=\(viewModel.hasActiveDevice)")
            await viewModel.handleStartStreaming()
          }
        }
      }
      .padding(24)
    }
    .sheet(isPresented: $wearablesVM.showGettingStartedSheet) {
      if #available(iOS 16.0, *) {
        GettingStartedSheetView(height: $sheetHeight)
          .presentationDetents([.height(sheetHeight)])
          .presentationDragIndicator(.visible)
      } else {
        GettingStartedSheetView(height: $sheetHeight)
      }
    }
  }
}

struct GettingStartedSheetView: View {
  @Environment(\.dismiss) var dismiss
  @Binding var height: CGFloat

  var body: some View {
    VStack(spacing: 24) {
      Text("사용 시작")
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.primary)

      VStack(spacing: 12) {
        TipItemView(
          resource: .videoIcon,
          text: "먼저 TurboMeta가 안경 카메라를 사용할 수 있도록 권한을 승인합니다."
        )
        TipItemView(
          resource: .tapIcon,
          text: "카메라 버튼을 누르면 안경 시점의 사진을 촬영합니다."
        )
        TipItemView(
          resource: .smartGlassesIcon,
          text: "촬영 또는 라이브 중에는 안경의 촬영 표시등이 켜져 주변 사람에게 알립니다."
        )
      }
      .padding(.bottom, 16)

      CustomButton(
        title: "계속",
        style: .primary,
        isDisabled: false
      ) {
        dismiss()
      }
    }
    .padding(24)
    .background(
      GeometryReader { geometry -> Color in
        DispatchQueue.main.async {
          height = geometry.size.height
        }
        return Color.clear
      }
    )
  }
}

struct TipItemView: View {
  let resource: ImageResource
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(resource)
        .resizable()
        .renderingMode(.template)
        .foregroundColor(.primary)
        .aspectRatio(contentMode: .fit)
        .frame(width: 24)
        .padding(.leading, 4)
        .padding(.top, 4)

      Text(text)
        .font(.system(size: 15))
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/*
 * Meta 안경으로 촬영한 사진 미리보기
 */

import SwiftUI

struct PhotoPreviewView: View {
  let photo: UIImage
  let onDismiss: () -> Void
  let onAIRecognition: (() -> Void)?
  let onLeanEat: (() -> Void)?

  @State private var showShareSheet = false
  @State private var dragOffset = CGSize.zero

  var body: some View {
    ZStack {
      Color.black.opacity(0.8)
        .ignoresSafeArea()
        .onTapGesture { dismissWithAnimation() }

      VStack(spacing: 20) {
        photoDisplayView

        VStack(spacing: 12) {
          HStack(spacing: 12) {
            if let onAIRecognition {
              Button(action: onAIRecognition) {
                Label("photo.ai".localized, systemImage: "brain")
                  .fontWeight(.semibold)
                  .frame(maxWidth: .infinity)
                  .padding()
                  .background(Color.blue)
                  .foregroundColor(.white)
                  .cornerRadius(12)
              }
            }

            if let onLeanEat {
              Button(action: onLeanEat) {
                Label("photo.nutrition".localized, systemImage: "chart.bar.fill")
                  .fontWeight(.semibold)
                  .frame(maxWidth: .infinity)
                  .padding()
                  .background(AppColors.leanEat)
                  .foregroundColor(.white)
                  .cornerRadius(12)
              }
            }
          }

          Button {
            showShareSheet = true
          } label: {
            Label("photo.share".localized, systemImage: "square.and.arrow.up")
              .fontWeight(.semibold)
              .frame(maxWidth: .infinity)
              .padding()
              .background(Color.gray.opacity(0.8))
              .foregroundColor(.white)
              .cornerRadius(12)
          }
        }
        .padding(.horizontal, 40)
      }
      .padding()
      .offset(dragOffset)
      .animation(.spring(response: 0.6, dampingFraction: 0.8), value: dragOffset)
    }
    .sheet(isPresented: $showShareSheet) {
      ShareSheet(photo: photo)
    }
  }

  private var photoDisplayView: some View {
    GeometryReader { geometry in
      Image(uiImage: photo)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height * 0.6)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
        .gesture(
          DragGesture()
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
              if abs(value.translation.height) > 100 {
                dismissWithAnimation()
              } else {
                withAnimation(.spring()) {
                  dragOffset = .zero
                }
              }
            }
        )
    }
  }

  private func dismissWithAnimation() {
    withAnimation(.easeInOut(duration: 0.3)) {
      dragOffset = CGSize(width: 0, height: UIScreen.main.bounds.height)
    }
    Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      onDismiss()
    }
  }
}

struct ShareSheet: UIViewControllerRepresentable {
  let photo: UIImage

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: [photo],
      applicationActivities: nil
    )
    controller.excludedActivityTypes = [.assignToContact, .addToReadingList]
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

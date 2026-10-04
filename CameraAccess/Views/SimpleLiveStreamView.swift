/*
 * 간단 라이브 화면
 * 화면 녹화 방식으로 외부 라이브 앱에 전달할 때 사용한다.
 */

import SwiftUI

struct SimpleLiveStreamView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUI = true

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            if let videoFrame = streamViewModel.currentVideoFrame {
                GeometryReader { geometry in
                    Image(uiImage: videoFrame)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .edgesIgnoringSafeArea(.all)
            } else {
                VStack(spacing: AppSpacing.lg) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("rtmp.connecting.video".localized)
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                }
            }

            if showUI {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white)
                                .padding()
                        }
                        .accessibilityLabel("닫기")

                        Spacer()

                        HStack(spacing: AppSpacing.sm) {
                            Circle()
                                .fill(streamViewModel.isStreaming ? Color.red : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(streamViewModel.isStreaming ? "라이브 중" : "연결 안 됨")
                                .font(AppTypography.caption)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(AppCornerRadius.lg)
                        .padding(AppSpacing.md)
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        Text("화면 녹화 방식 안내")
                            .font(AppTypography.headline)
                            .foregroundColor(.white)

                        Text("1. 사용할 라이브 플랫폼 앱을 엽니다")
                        Text("2. iPhone 제어 센터에서 화면 기록을 시작합니다")
                        Text("3. 이 화면으로 돌아와 안경 영상을 송출합니다")
                    }
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(AppSpacing.lg)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(AppCornerRadius.lg)
                    .padding(.bottom, AppSpacing.xl)
                }
                .transition(.opacity)
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showUI.toggle()
            }
        }
        .onAppear {
            Task {
                print("[SimpleLive][INFO] 영상 스트림 시작 요청")
                await streamViewModel.handleStartStreaming()
            }
        }
        .onDisappear {
            Task {
                print("[SimpleLive][INFO] 화면 종료 status=\(streamViewModel.streamingStatus)")
                if streamViewModel.streamingStatus != .stopped {
                    await streamViewModel.stopSession()
                }
            }
        }
    }
}

/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// 개발 중 개별 모의 Meta 기기의 전원, 착용, 접힘 상태와 테스트 미디어를 관리한다.

#if DEBUG

import SwiftUI

struct MockDeviceCardView: View {
  @ObservedObject var viewModel: ViewModel
  let onUnpairDevice: () -> Void
  @State private var showingVideoPicker = false
  @State private var showingImagePicker = false

  var body: some View {
    CardView {
      VStack(spacing: 8) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.deviceName)
              .font(.headline)
              .foregroundColor(.primary)
              .lineLimit(1)
            Text(viewModel.id)
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          MockDeviceKitButton("연결 해제", style: .destructive, expandsHorizontally: false) {
            onUnpairDevice()
          }
        }

        Divider()

        VStack(spacing: 8) {
          HStack(spacing: 8) {
            MockDeviceKitButton("전원 켜기") {
              viewModel.powerOn()
            }

            MockDeviceKitButton("전원 끄기") {
              viewModel.powerOff()
            }
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("착용") {
              viewModel.don()
            }

            MockDeviceKitButton("벗기") {
              viewModel.doff()
            }
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("펼치기") {
              viewModel.unfold()
            }

            MockDeviceKitButton("접기") {
              viewModel.fold()
            }
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("비디오 선택") {
              showingVideoPicker = true
            }
            .sheet(isPresented: $showingVideoPicker) {
              MediaPickerView(mode: .video) { url, _ in
                viewModel.selectVideo(from: url)
              }
            }

            StatusText(
              isActive: viewModel.hasCameraFeed,
              activeText: "카메라 영상 있음",
              inactiveText: "카메라 영상 없음"
            )
          }

          HStack(spacing: 8) {
            MockDeviceKitButton("이미지 선택") {
              showingImagePicker = true
            }
            .sheet(isPresented: $showingImagePicker) {
              MediaPickerView(mode: .image) { url, _ in
                viewModel.selectImage(from: url)
              }
            }

            StatusText(
              isActive: viewModel.hasCapturedImage,
              activeText: "촬영 이미지 있음",
              inactiveText: "촬영 이미지 없음"
            )
          }
        }
      }
      .padding()
    }
  }
}

#endif

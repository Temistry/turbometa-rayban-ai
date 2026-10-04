/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// 개발 중 실제 Meta 기기 없이 페어링, 기능과 상태를 시험하는 DEBUG 전용 화면이다.

#if DEBUG

import Foundation
import SwiftUI

struct MockDeviceKitView: View {
  @ObservedObject var viewModel: ViewModel

  var body: some View {
    NavigationView {
      ScrollView {
        VStack(spacing: 16) {
          CardView {
            VStack(spacing: 8) {
              HStack {
                Text("모의 기기 도구")
                  .font(.title2)
                  .foregroundColor(.primary)
                Spacer()

                Text("페어링된 기기 \(viewModel.cardViewModels.count)개")
                  .font(.subheadline)
                  .foregroundColor(.green)
              }

              Text("가상 기기를 만들고 기능과 연결 상태를 시험하는 개발용 화면입니다")
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

              Divider()

              MockDeviceKitButton("Ray-Ban Meta 페어링", disabled: viewModel.cardViewModels.count > 2) {
                viewModel.pairRaybanMeta()
              }
            }
            .padding()
          }

          ForEach(viewModel.cardViewModels, id: \.id) { cardViewModel in
            MockDeviceCardView(
              viewModel: cardViewModel,
              onUnpairDevice: {
                viewModel.unpairDevice(cardViewModel.device)
              }
            )
          }

          Spacer()
        }
        .padding()
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("모의 Meta 기기")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

#endif

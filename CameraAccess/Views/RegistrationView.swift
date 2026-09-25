/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import SwiftUI

struct RegistrationView: View {
  @ObservedObject var viewModel: WearablesViewModel

  var body: some View {
    EmptyView()
      .onOpenURL { url in
        guard
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else {
          print("[Registration][INFO] DAT SDK와 무관한 URL 콜백 무시 scheme=\(url.scheme ?? "-") host=\(url.host ?? "-")")
          return
        }

        print("[Registration][INFO] Meta DAT SDK 콜백 수신 scheme=\(url.scheme ?? "-") queryItemCount=\(components.queryItems?.count ?? 0)")

        Task {
          do {
            _ = try await Wearables.shared.handleUrl(url)
            print("[Registration][INFO] Meta DAT SDK 콜백 처리 성공")
          } catch let error as RegistrationError {
            print("[Registration][ERROR] 등록 오류 description=\(error.description)")
            viewModel.showError(error.description)
          } catch {
            let nsError = error as NSError
            let message = "등록 처리 중 오류가 발생했습니다. \(error.localizedDescription)"
            print("[Registration][ERROR] 알 수 없는 등록 오류 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            viewModel.showError(message)
          }
        }
      }
  }
}

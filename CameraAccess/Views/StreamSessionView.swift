/*
 * Meta 안경 스트림 세션 화면
 */

import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  let wearables: WearablesInterface
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @StateObject private var viewModel: StreamSessionViewModel

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      } else {
        NonStreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
      }
    }
    .alert("오류", isPresented: $viewModel.showError) {
      Button("확인") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}

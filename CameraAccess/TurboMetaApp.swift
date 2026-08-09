/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppIntents
import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct TurboMetaApp: App {
  #if DEBUG
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(
    mockDeviceKit: MockDeviceKit.shared
  )
  #endif

  @StateObject private var developerConsole = DeveloperConsole.shared

  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    #if DEBUG || INTERNAL_BUILD
    // 내부 TestFlight 빌드는 사용자가 직접 공유할 수 있는 보호된 기기 로그를 남긴다.
    DeveloperConsole.shared.startCapturing()
    #endif

    if #available(iOS 16.0, *) {
      TurboMetaShortcuts.updateAppShortcutParameters()
      DeveloperConsole.shared.log(
        .info,
        category: "Siri",
        "한국어 App Shortcut 등록 정보 갱신 요청 완료"
      )
    }

    do {
      try Wearables.configure()
      DeveloperConsole.shared.log(
        .info,
        category: "TurboMeta",
        "Wearables SDK 설정 성공"
      )
    } catch {
      DeveloperConsole.shared.record(
        error: error,
        category: "TurboMeta",
        operation: "Wearables.configure"
      )
    }

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(
      wrappedValue: WearablesViewModel(wearables: wearables)
    )
  }

  var body: some Scene {
    WindowGroup {
      ZStack(alignment: .bottomTrailing) {
        MainAppView(wearables: wearables, viewModel: wearablesViewModel)
          .alert("오류", isPresented: $wearablesViewModel.showError) {
            Button("확인") {
              wearablesViewModel.dismissError()
            }
          } message: {
            Text(wearablesViewModel.errorMessage)
          }

        RegistrationView(viewModel: wearablesViewModel)

        #if DEBUG || INTERNAL_BUILD
        DeveloperConsoleButton(console: developerConsole)
          .padding(.trailing, 12)
          .padding(.bottom, 90)
          .accessibilityIdentifier("developer_console_button")
        #endif

        #if DEBUG
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
          .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
            MockDeviceKitView(
              viewModel: debugMenuViewModel.mockDeviceKitViewModel
            )
          }
        #endif
      }
      .environment(\.locale, Locale(identifier: "ko-KR"))
      .onChange(of: wearablesViewModel.showError) { isPresented in
        guard isPresented else { return }
        developerConsole.log(
          .error,
          category: "WearablesUI",
          wearablesViewModel.errorMessage
        )
      }
      .fullScreenCover(isPresented: $developerConsole.isPresented) {
        DeveloperLogView(console: developerConsole)
      }
    }
  }
}

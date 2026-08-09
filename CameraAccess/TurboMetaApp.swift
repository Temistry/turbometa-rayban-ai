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
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif

  @StateObject private var developerConsole = DeveloperConsole.shared

  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    #if DEBUG || INTERNAL_BUILD
    // Debug 및 내부 TestFlight 빌드에서만 기기 내 로그를 캡처한다.
    DeveloperConsole.shared.startCapturing()
    #endif

    // App Shortcut 문구나 파라미터가 바뀐 경우 시스템 등록 정보를 갱신한다.
    if #available(iOS 16.0, *) {
      TurboMetaShortcuts.updateAppShortcutParameters()
      print("[Siri][INFO] 한국어 App Shortcut 등록 정보 갱신 요청 완료")
    }

    do {
      try Wearables.configure()
      print("[TurboMeta][INFO] Wearables SDK 설정 성공")
    } catch {
      let nsError = error as NSError
      print("[TurboMeta][ERROR] Wearables.configure 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
    }

    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
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
        // 로그는 메모리에만 보관되며 자격 증명과 대용량 payload는 마스킹된다.
        DeveloperConsoleButton(console: developerConsole)
          .padding(.trailing, 14)
          .padding(.bottom, 92)
        #endif

        #if DEBUG
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
          .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
            MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
          }
        #endif
      }
      .environment(\.locale, Locale(identifier: "ko-KR"))
      .fullScreenCover(isPresented: $developerConsole.isPresented) {
        DeveloperLogView(console: developerConsole)
      }
    }
  }
}

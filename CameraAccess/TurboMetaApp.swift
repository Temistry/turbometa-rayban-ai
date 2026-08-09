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
    // TestFlight에서도 Xcode 없이 원인을 확인할 수 있도록 가장 먼저 로그를 캡처한다.
    DeveloperConsole.shared.startCapturing()

    // App Shortcut 문구나 파라미터가 바뀐 경우 시스템 등록 정보를 즉시 갱신한다.
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

        // DAT SDK 등록 및 권한 콜백을 처리하는 보이지 않는 뷰다.
        RegistrationView(viewModel: wearablesViewModel)

        // 내부/TestFlight 진단용. 로그는 기기 메모리에만 보관되고 자격 증명은 마스킹된다.
        DeveloperConsoleButton(console: developerConsole)
          .padding(.trailing, 14)
          .padding(.bottom, 92)

        #if DEBUG
        // 물리 안경 없이 테스트해야 할 때 사용하는 Meta Mock Device 메뉴다.
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

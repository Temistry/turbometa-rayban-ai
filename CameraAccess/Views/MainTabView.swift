/*
 * Main Tab View
 * 한국어 전용 하단 탭과 Google Gemini 단일 인증 경로를 구성한다.
 */

import SwiftUI

struct MainTabView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject var wearablesViewModel: WearablesViewModel

    @State private var selectedTab = 0

    private var apiKey: String {
        APIKeyManager.shared.getGoogleAPIKey() ?? ""
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            TurboMetaHomeView(
                streamViewModel: streamViewModel,
                wearablesViewModel: wearablesViewModel,
                apiKey: apiKey
            )
            .tabItem {
                Label("tab.home".localized, systemImage: "house.fill")
            }
            .tag(0)

            RecordsView()
                .tabItem {
                    Label("tab.records".localized, systemImage: "list.bullet.rectangle")
                }
                .tag(1)

            GalleryView()
                .tabItem {
                    Label("tab.gallery".localized, systemImage: "photo.on.rectangle")
                }
                .tag(2)

            UnifiedSettingsView(streamViewModel: streamViewModel)
                .tabItem {
                    Label("tab.settings".localized, systemImage: "person.fill")
                }
                .tag(3)
        }
        .accentColor(AppColors.primary)
    }
}

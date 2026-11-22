import SwiftUI

enum MainTab: Hashable {
    case extractor
    case search
    case library
    case accounts
}

struct ContentView: View {
    @EnvironmentObject private var manager: AppStoreManager
    @State private var selectedTab: MainTab = .extractor

    var body: some View {
        TabView(selection: $selectedTab) {
            AppIDExtractorView(selectedTab: $selectedTab)
                .tabItem {
                    Label("По App ID", systemImage: "arrow.down.doc.fill")
                }
                .tag(MainTab.extractor)

            SearchView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Поиск", systemImage: "magnifyingglass")
                }
                .tag(MainTab.search)

            LibraryView()
                .tabItem {
                    Label("Файлы IPA", systemImage: "archivebox.fill")
                }
                .tag(MainTab.library)

            AccountsView()
                .tabItem {
                    Label("Аккаунты", systemImage: "person.crop.circle.fill")
                }
                .tag(MainTab.accounts)
        }
    }
}

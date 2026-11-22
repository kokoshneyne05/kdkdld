import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: VaultController

    var body: some View {
        TabView(selection: $controller.selectedTab) {
            DeletedExtractorView()
                .tabItem {
                    Label("Удалённые / ID", systemImage: "archivebox.fill")
                }
                .tag(0)

            CatalogSearchView()
                .tabItem {
                    Label("Поиск", systemImage: "magnifyingglass")
                }
                .tag(1)

            DownloadsLibraryView()
                .tabItem {
                    Label("Файлы IPA", systemImage: "doc.zipper")
                }
                .tag(2)

            AccountAnisetteView()
                .tabItem {
                    Label("Аккаунт", systemImage: "person.badge.key.fill")
                }
                .tag(3)
        }
    }
}

import SwiftUI

@main
struct IPAVaultApp: App {
    @StateObject private var manager = AppStoreManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}

import SwiftUI

@main
struct IPAVaultApp: App {
    @StateObject private var controller = VaultController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .onAppear {
                    controller.bootstrap()
                }
        }
    }
}

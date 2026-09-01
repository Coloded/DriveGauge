import SwiftUI

@main
struct DriveGaugeApp: App {
    private let updates = UpdateController.shared

    init() {
        updates.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1180, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") {
                    updates.checkForUpdates()
                }
            }
        }
    }
}

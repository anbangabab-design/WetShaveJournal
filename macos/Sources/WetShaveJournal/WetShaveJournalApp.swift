import SwiftUI

@main
struct WetShaveJournalApp: App {
    @StateObject private var store = JournalStore()
    @StateObject private var updateService = UpdateService.shared

    var body: some Scene {
        WindowGroup("WetShaveJournal") {
            ContentView()
                .environmentObject(store)
                .environmentObject(updateService)
                .preferredColorScheme(store.appearanceMode.colorScheme)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.t("检查更新…", "Check for Updates…")) {
                    Task { await updateService.checkForUpdates(manual: true, presentAlertOnNoUpdate: true) }
                }
                .disabled(updateService.isChecking)
            }
        }
    }
}

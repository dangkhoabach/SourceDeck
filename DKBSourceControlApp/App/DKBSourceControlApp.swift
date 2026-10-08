import SwiftUI

@main
struct DKBSourceControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(AppLocale.key) private var languageRaw = AppLocale.systemDefault.rawValue

    private var appLocale: AppLocale {
        AppLocale(rawValue: languageRaw) ?? .systemDefault
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, appLocale.locale)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            // One main window (plan D4): every repository is a sidebar entry
            // of it, so File › New Window would only open a duplicate.
            CommandGroup(replacing: .newItem) {
                Button("Add Repository…") { AppServices.shared.repositories?.chooseFoldersToAdd() }
                    .keyboardShortcut("o")
                Button("Scan Folder…") { AppServices.shared.repositories?.isScanSheetPresented = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Dashboard") { AppServices.shared.repositories?.selection = .dashboard }
                    .keyboardShortcut("0")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(\.locale, appLocale.locale)
        }
    }
}

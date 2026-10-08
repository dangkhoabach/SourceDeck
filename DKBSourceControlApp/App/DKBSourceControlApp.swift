import SwiftUI

@main
struct DKBSourceControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(AppLocale.key) private var languageRaw = AppLocale.systemDefault.rawValue

    private var appLocale: AppLocale {
        AppLocale(rawValue: languageRaw) ?? .systemDefault
    }

    /// ⌘1 / ⌘2 / ⌘3 on the repository in the window (plan §7.2).
    @MainActor private func show(_ tab: RepositoryModel.Tab) {
        AppServices.shared.repositories?.selectedModel?.tab = tab
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
                Button("Clone Repository…") { AppServices.shared.repositories?.isCloneSheetPresented = true }
                    .keyboardShortcut("n")
                Button("Add Repository…") { AppServices.shared.repositories?.chooseFoldersToAdd() }
                    .keyboardShortcut("o")
                Button("Scan Folder…") { AppServices.shared.repositories?.isScanSheetPresented = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Dashboard") { AppServices.shared.repositories?.selection = .dashboard }
                    .keyboardShortcut("0")
                Button("Working Copy") { show(.workingCopy) }
                    .keyboardShortcut("1")
                Button("History") { show(.history) }
                    .keyboardShortcut("2")
                Button("Branches") { show(.branches) }
                    .keyboardShortcut("3")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(\.locale, appLocale.locale)
        }
    }
}

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
        .commands {
            // One main window (plan D4): every repository is a sidebar entry
            // of it, so File › New Window would only open a duplicate.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(\.locale, appLocale.locale)
        }
    }
}

import AppKit

/// AppKit glue SwiftUI Scenes don't expose: apply the theme before the first
/// window draws, then resolve git in the background and start the updater;
/// save the commit drafts on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One main window (plan D4): no window tabs, so View has no tab items.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the app's tests, which make their own repositories: the
        // list would read, and fetch, the user's real ones.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        ThemePreference.apply()
        Task { await AppServices.shared.start() }
        _ = AppUpdater.shared   // starts Sparkle's scheduled check (the controller is lazy)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.repositories?.saveDrafts()
    }
}

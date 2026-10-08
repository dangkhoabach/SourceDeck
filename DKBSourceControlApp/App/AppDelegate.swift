import AppKit

/// AppKit glue SwiftUI Scenes don't expose: apply the theme before the first
/// window draws, then resolve git in the background; save the commit drafts
/// on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One main window (plan D4): no window tabs, so View has no tab items.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemePreference.apply()
        Task { await AppServices.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.repositories?.saveDrafts()
    }
}

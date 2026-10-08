import AppKit

/// AppKit glue SwiftUI Scenes don't expose: apply the theme before the first
/// window draws, then resolve git in the background.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemePreference.apply()
        Task { await AppServices.shared.start() }
    }
}

import AppKit
import SwiftUI

/// Brings the main window forward, or opens it when there is none, and opens
/// Settings: the same steps for the menu bar panel and its right-click menu.
@MainActor
enum WindowPresenter {
    static let mainWindowID = "main"
    /// SwiftUI's own actions, kept by the status item (`WindowActionsKeeper`).
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?

    static func showMainWindow() {
        NSApp.unhide(nil)
        // `openWindow` makes a new window every time for a window group, so
        // only when there is none: closing the window ends it in this app.
        let windows = mainWindows(in: NSApp.windows)
        if windows.isEmpty {
            openWindow?(id: mainWindowID)
        } else {
            windows.forEach { $0.makeKeyAndOrderFront(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The main window group's windows, by the identifier SwiftUI gives them
    /// (`main-AppWindow-1`); `NSApp.windows` also holds the menu bar panel,
    /// Settings and the About window.
    static func mainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.identifier?.rawValue.hasPrefix(mainWindowID) == true }
    }

    static func showSettings() {
        openSettings?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One repository, selected in the main window.
    static func show(repositoryID: String) {
        AppServices.shared.repositories?.selection = .repository(repositoryID)
        showMainWindow()
    }
}

/// Keeps SwiftUI's `openWindow` and `openSettings` for `WindowPresenter`. It
/// sits, with no size, in the status item, which is there from launch whether
/// or not the main window is.
struct WindowActionsKeeper: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowPresenter.openWindow = openWindow
                WindowPresenter.openSettings = openSettings
            }
    }
}

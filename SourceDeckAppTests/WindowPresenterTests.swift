import AppKit
import Testing
@testable import SourceDeck

@MainActor
@Suite struct WindowPresenterTests {
    /// With the main window closed, Show SourceDeck in the menu bar panel
    /// opens one; with it open, it brings that one forward and opens no other.
    @Test func showMainWindowOpensOneOnlyWhenThereIsNone() async throws {
        WindowPresenter.mainWindows(in: NSApp.windows).forEach { $0.close() }
        #expect(WindowPresenter.openWindow != nil)

        WindowPresenter.showMainWindow()
        func shown() -> [NSWindow] { WindowPresenter.mainWindows(in: NSApp.windows).filter(\.isVisible) }
        for _ in 0..<40 where shown().isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shown().count == 1)

        WindowPresenter.showMainWindow()
        try await Task.sleep(for: .milliseconds(300))
        #expect(shown().count == 1)
    }
}

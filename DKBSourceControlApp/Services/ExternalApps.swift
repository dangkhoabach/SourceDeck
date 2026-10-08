import AppKit

/// "Open in…" (plan F9): the apps of this kind installed on the Mac, with
/// their own name and icon. Nothing is shown for an app that isn't there.
struct ExternalApp: Identifiable {
    let bundleID: String
    let url: URL
    let name: String

    var id: String { bundleID }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// Terminals, editors (VS Code and its forks) and the other git clients.
    static let candidates = [
        "com.apple.Terminal", "com.googlecode.iterm2",
        "com.microsoft.VSCode", "com.google.antigravity-ide", "com.todesktop.230313mzl4w4u92",
        sourcetree, "com.DanPristupov.Fork",
    ]

    /// Where conflicts get resolved: this app has no conflict editor (plan D17).
    static let sourcetree = "com.torusknot.SourceTreeNotMAS"

    /// Looked up once: apps are rarely installed while this one runs.
    @MainActor static let installed: [ExternalApp] = candidates.compactMap { bundleID in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return ExternalApp(bundleID: bundleID, url: url, name: name)
    }

    @MainActor func open(_ folder: URL) {
        NSWorkspace.shared.open([folder], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor static func revealInFinder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

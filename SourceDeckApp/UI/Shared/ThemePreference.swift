import AppKit
import SwiftUI

/// Light / Dark / System, same key and behavior as SignalBar and
/// KeyCellar. Applied through `NSApp.appearance` (nil = follow the system)
/// because `.preferredColorScheme(nil)` does not reliably clear an explicit
/// scheme from an already-visible window.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    static let key = "themePreference"

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Reads the stored choice and applies it — at launch (there is no main
    /// window whose `onAppear` could do it) and whenever Settings changes it.
    @MainActor
    static func apply() {
        let theme = UserDefaults.standard.string(forKey: key).flatMap(ThemePreference.init(rawValue:)) ?? .system
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

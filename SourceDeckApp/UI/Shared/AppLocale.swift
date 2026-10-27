import Foundation

/// In-app language override, independent of System Settings > Language &
/// Region (ported from DKB Clamshell). Views use `LocalizedStringKey`
/// everywhere, so overriding `\.locale` on the root views in
/// `SourceDeckApp.swift` makes the switch take effect. A sheet doesn't
/// get that override (macOS 27: Clone and Sign In came up in English), so
/// every sheet's content sets it again from `current`.
enum AppLocale: String, CaseIterable, Identifiable {
    case en, vi

    var id: Self { self }

    static let key = "languagePreference"

    var locale: Locale { Locale(identifier: rawValue) }

    /// Falls back to the system's language exactly once, on first launch,
    /// before the user has picked anything in Settings.
    static var systemDefault: AppLocale {
        Locale.current.language.languageCode?.identifier == "vi" ? .vi : .en
    }

    /// The language picked in Settings, or the system's until one is picked.
    static var current: AppLocale {
        UserDefaults.standard.string(forKey: key).flatMap(AppLocale.init(rawValue:)) ?? systemDefault
    }

    /// The `.lproj` bundle of the in-app language, for `String(localized:bundle:)`
    /// (ported from DKB Clamshell). `String(localized:)` alone reads the
    /// *system* language and ignores the `\.locale` override the views get,
    /// so text AppKit draws itself — the window title — goes through this.
    static var bundle: Bundle {
        Bundle.main.path(forResource: current.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

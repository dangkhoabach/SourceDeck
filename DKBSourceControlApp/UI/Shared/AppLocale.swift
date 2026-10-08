import Foundation

/// In-app language override, independent of System Settings > Language &
/// Region (ported from DKB Clamshell). Views use `LocalizedStringKey`
/// everywhere, so overriding `\.locale` on the root views in
/// `DKBSourceControlApp.swift` is enough to make the switch take effect.
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
}

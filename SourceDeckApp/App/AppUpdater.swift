import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`, copied from
/// DKB Clamshell / DKB Monitor: it reads `SUFeedURL` and `SUPublicEDKey`
/// straight from Info.plist, so "check on launch + Check for Updates…"
/// needs no delegate.
///
/// Whether it checks on its own is the user's answer, not a build setting:
/// Info.plist does not pin `SUEnableAutomaticChecks`, so Sparkle asks on the
/// second launch and stores the reply, and `automaticallyChecksForUpdates`
/// below is the same stored value that Settings › Updates reads and writes.
///
/// `shared` is lazy, so `AppDelegate` touches it at launch — otherwise the
/// scheduled check never starts until the user opens the menu item.
@MainActor
enum AppUpdater {
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Round-trips Sparkle's own preference rather than shadowing it in
    /// `@AppStorage`: a second copy would drift from the answer Sparkle
    /// actually acts on.
    static var automaticallyChecksForUpdates: Bool {
        get { shared.updater.automaticallyChecksForUpdates }
        set { shared.updater.automaticallyChecksForUpdates = newValue }
    }

    static func checkForUpdates() {
        shared.checkForUpdates(nil)
    }
}

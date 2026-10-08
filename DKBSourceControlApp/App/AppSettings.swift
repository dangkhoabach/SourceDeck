import DKBSourceControlCore
import Foundation

/// The preferences kept in `UserDefaults` (plan D11). Views bind to the
/// same keys with `@AppStorage`; models read them here.
enum AppSettings {
    static let pullModeKey = "pullMode"
    static let autoFetchMinutesKey = "autoFetchMinutes"
    static let lastSelectedRepositoryKey = "lastSelectedRepositoryId"

    /// Fast-forward only unless the user chose rebase (plan D13).
    static var pullMode: PullMode {
        UserDefaults.standard.string(forKey: pullModeKey).flatMap(PullMode.init(rawValue:)) ?? .fastForwardOnly
    }

    /// 0 = off, the default (plan F5).
    static var autoFetchMinutes: Int {
        UserDefaults.standard.integer(forKey: autoFetchMinutesKey)
    }

    static let autoFetchChoices = [0, 5, 15, 30, 60]
}

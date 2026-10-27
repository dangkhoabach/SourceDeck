import SourceDeckCore
import Foundation

/// The preferences kept in `UserDefaults`. Views bind to the
/// same keys with `@AppStorage`; models read them here.
enum AppSettings {
    static let gitPathKey = "gitPath"
    static let pullModeKey = "pullMode"
    static let autoFetchMinutesKey = "autoFetchMinutes"
    static let lastSelectedRepositoryKey = "lastSelectedRepositoryId"
    static let diffContextKey = "diffContext"
    static let diffIgnoresWhitespaceKey = "diffIgnoresWhitespace"
    static let fileListLayoutKey = "fileListLayout"
    static let cloneParentFolderKey = "cloneParentFolder"

    /// `/usr/bin/git` unless the user chose another one; read at launch.
    static var gitPath: String {
        let path = UserDefaults.standard.string(forKey: gitPathKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.isEmpty ? GitEnvironment.defaultGitPath : path
    }

    /// Fast-forward only unless the user chose rebase.
    static var pullMode: PullMode {
        UserDefaults.standard.string(forKey: pullModeKey).flatMap(PullMode.init(rawValue:)) ?? .fastForwardOnly
    }

    /// 0 = off, the default.
    static var autoFetchMinutes: Int {
        UserDefaults.standard.integer(forKey: autoFetchMinutesKey)
    }

    static let autoFetchChoices = [0, 5, 15, 30, 60]

    /// The diff viewer's last choice: 3 lines of context and whitespace
    /// shown until changed.
    static var diffOptions: DiffOptions {
        let context = UserDefaults.standard.integer(forKey: diffContextKey)
        return DiffOptions(context: context > 0 ? context : 3,
                           ignoresWhitespace: UserDefaults.standard.bool(forKey: diffIgnoresWhitespaceKey))
    }
}

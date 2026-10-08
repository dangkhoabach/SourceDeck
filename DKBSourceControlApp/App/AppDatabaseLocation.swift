import Foundation

/// `~/Library/Application Support/com.dangkhoabach.dkb-source-control/dkb-source-control.db`.
/// Debug builds keep their own file, so trying things out from Xcode never
/// reorders or removes the repository list the installed Release build uses.
enum AppDatabaseLocation {
    static func productionPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.dangkhoabach.dkb-source-control", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    #if DEBUG
    static let fileName = "dkb-source-control-debug.db"
    #else
    static let fileName = "dkb-source-control.db"
    #endif
}

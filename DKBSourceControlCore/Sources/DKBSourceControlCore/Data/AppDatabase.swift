import Foundation
import GRDB

/// Opens (or creates) the app's SQLite database and keeps it migrated.
///
/// Holds only what git doesn't: which repositories the user added and in
/// what order (plan §5.4). Nothing about a repository's contents, history or
/// credentials is ever stored here. Light preferences (theme, language, git
/// path) live in `UserDefaults`, where the shared DKB `@AppStorage` helpers
/// already read them.
public struct AppDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory database for tests/previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_repositories") { db in
            try db.execute(sql: """
                CREATE TABLE repositories (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    added_at TEXT NOT NULL
                );
                """)
        }

        return migrator
    }
}

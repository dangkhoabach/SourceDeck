import Foundation
import GRDB

/// Opens (or creates) the app's SQLite database and keeps it migrated.
///
/// Holds only what git doesn't: which repositories the user added, in what
/// order, and the commit message being written for each.
/// Nothing about a repository's contents, history or credentials is ever
/// stored here. Light preferences (theme, language, git path) live in
/// `UserDefaults`, where the shared `@AppStorage` helpers already read
/// them.
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

        migrator.registerMigration("v2_commit_drafts") { db in
            try db.execute(sql: """
                CREATE TABLE commit_drafts (
                    repository_id TEXT PRIMARY KEY REFERENCES repositories(id) ON DELETE CASCADE,
                    keyword TEXT NOT NULL,
                    outline_json TEXT NOT NULL,
                    raw_text TEXT,
                    push_after_commit INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                );
                """)
        }

        // The picture shown instead of the initials: a square PNG, or NULL.
        // `.immediate`: checks only what this migration writes. GRDB's
        // default checks every foreign key afterwards, and a draft left
        // without its repository by an early sandbox then stopped the list
        // from opening.
        migrator.registerMigration("v3_repository_avatar", foreignKeyChecks: .immediate) { db in
            try db.execute(sql: "ALTER TABLE repositories ADD COLUMN avatar BLOB")
        }

        return migrator
    }
}

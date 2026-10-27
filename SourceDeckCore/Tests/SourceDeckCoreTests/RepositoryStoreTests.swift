import Foundation
import GRDB
import Testing
@testable import SourceDeckCore

@Suite struct RepositoryStoreTests {
    private func makeStore() throws -> RepositoryStore {
        RepositoryStore(dbQueue: try AppDatabase.inMemory().dbQueue)
    }

    @Test func addingNamesAfterTheFolderAndAppendsToTheEnd() throws {
        let store = try makeStore()
        let a = try store.add(path: "/Users/x/MyWebsite")
        let b = try store.add(path: "/Users/x/Cà Phê Tý Mập")
        #expect(a.name == "MyWebsite")
        #expect(b.name == "Cà Phê Tý Mập")
        #expect(b.sortOrder == a.sortOrder + 1)
        #expect(try store.all().map(\.path) == ["/Users/x/MyWebsite", "/Users/x/Cà Phê Tý Mập"])
    }

    @Test func addingTheSamePathTwiceReturnsTheExistingRecord() throws {
        let store = try makeStore()
        let first = try store.add(path: "/Users/x/repo")
        let again = try store.add(path: "/Users/x/repo")
        // Same record; `addedAt` comes back from SQLite at millisecond precision.
        #expect(first.id == again.id)
        #expect(try store.all().count == 1)
    }

    @Test func renameAndResetToTheFolderName() throws {
        let store = try makeStore()
        let record = try store.add(path: "/Users/x/MyWebsite")
        try store.rename(id: record.id, to: "  Portfolio  ")
        #expect(try store.all().first?.name == "Portfolio")
        try store.rename(id: record.id, to: " ")
        #expect(try store.all().first?.name == "MyWebsite")
    }

    @Test(arguments: [
        ("SourceDeck", "SD"), ("CaPheSuaDa", "CP"), ("iHub", "IH"), ("KTVinaLogistics", "KL"),
        ("dangkhoabach-Workspace", "DW"), ("Cà Phê Tý Mập", "CP"), ("repo", "R"), ("my_website v2", "MW"), ("2024 notes", "2N"),
    ])
    func initialsAreTheFirstLettersOfTheFirstTwoWords(name: String, initials: String) {
        #expect(RepositoryRecord(path: "/x", name: name, sortOrder: 0).initials == initials)
    }

    @Test func anAvatarIsSavedAndRemoved() throws {
        let store = try makeStore()
        let record = try store.add(path: "/Users/x/repo")
        #expect(record.avatar == nil)
        try store.setAvatar(id: record.id, to: Data([1, 2, 3]))
        #expect(try store.all().first?.avatar == Data([1, 2, 3]))
        try store.setAvatar(id: record.id, to: nil)
        #expect(try store.all().first?.avatar == nil)
    }

    /// A list made before avatars keeps every repository and its draft.
    @Test func theAvatarMigrationKeepsExistingRepositories() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v2_commit_drafts")
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO repositories VALUES ('a', '/Users/x/repo', 'Repo', 0, '2026-10-09 10:00:00.000')")
        }
        try AppDatabase.migrator.migrate(dbQueue)
        let records = try RepositoryStore(dbQueue: dbQueue).all()
        #expect(records.map(\.name) == ["Repo"] && records.first?.avatar == nil)
    }

    /// A draft whose repository is gone (left on the owner's debug database
    /// by an early sandbox) must not stop the list from opening: GRDB's
    /// default check after a migration looks at every foreign key.
    @Test func theAvatarMigrationRunsOverADraftWithoutItsRepository() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v2_commit_drafts")
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO commit_drafts VALUES ('SANDBOX-0000', 'Update', '[]', NULL, 0, '2026-10-08 15:50:24.649')
                """)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        try AppDatabase.migrator.migrate(dbQueue)
        #expect(try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM commit_drafts") } == 1)
    }

    /// Arguments as SwiftUI's `onMove` passes them.
    @Test(arguments: [
        (IndexSet([0]), 3, ["b", "c", "a", "d"]),
        (IndexSet([3]), 0, ["d", "a", "b", "c"]),
        (IndexSet([0, 2]), 4, ["b", "d", "a", "c"]),
        (IndexSet([1]), 1, ["a", "b", "c", "d"]),
    ])
    func moveRenumbersTheWholeList(source: IndexSet, destination: Int, expected: [String]) throws {
        let store = try makeStore()
        for name in ["a", "b", "c", "d"] { try store.add(path: "/\(name)") }
        try store.move(fromOffsets: source, toOffset: destination)
        let all = try store.all()
        #expect(all.map(\.name) == expected)
        #expect(all.map(\.sortOrder) == [0, 1, 2, 3])
    }

    @Test func removeDeletesOnlyThatRecord() throws {
        let store = try makeStore()
        let a = try store.add(path: "/a")
        try store.add(path: "/b")
        try store.remove(id: a.id)
        #expect(try store.all().map(\.path) == ["/b"])
    }
}

@Suite struct RepositoryStoreUpdatesTests {
    @Test func updatesStartWithTheCurrentListAndFollowChanges() async throws {
        let store = RepositoryStore(dbQueue: try AppDatabase.inMemory().dbQueue)
        try store.add(path: "/a")
        var iterator = store.updates().makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.path) == ["/a"])
        try store.add(path: "/b")
        #expect(try await iterator.next()?.map(\.path) == ["/a", "/b"])
    }
}

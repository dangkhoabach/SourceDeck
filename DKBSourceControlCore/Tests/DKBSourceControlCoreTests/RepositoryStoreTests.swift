import Foundation
import Testing
@testable import DKBSourceControlCore

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

    @Test func removeDeletesOnlyThatRecord() throws {
        let store = try makeStore()
        let a = try store.add(path: "/a")
        try store.add(path: "/b")
        try store.remove(id: a.id)
        #expect(try store.all().map(\.path) == ["/b"])
    }
}

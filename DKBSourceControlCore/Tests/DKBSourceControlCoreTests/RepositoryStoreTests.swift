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

    @Test func renameAndResetToTheFolderName() throws {
        let store = try makeStore()
        let record = try store.add(path: "/Users/x/MyWebsite")
        try store.rename(id: record.id, to: "  Portfolio  ")
        #expect(try store.all().first?.name == "Portfolio")
        try store.rename(id: record.id, to: " ")
        #expect(try store.all().first?.name == "MyWebsite")
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

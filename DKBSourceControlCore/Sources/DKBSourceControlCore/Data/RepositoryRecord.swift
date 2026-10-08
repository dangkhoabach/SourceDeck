import Foundation
import GRDB

/// A repository the user added to the sidebar. `path` is the work tree's
/// top level; removing the record never touches the folder on disk.
public struct RepositoryRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var name: String
    public var sortOrder: Int
    public var addedAt: Date

    public init(id: String = UUID().uuidString, path: String, name: String, sortOrder: Int, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.name = name
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

extension RepositoryRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repositories"

    enum CodingKeys: String, CodingKey {
        case id, path, name
        case sortOrder = "sort_order"
        case addedAt = "added_at"
    }
}

public struct RepositoryStore: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func all() throws -> [RepositoryRecord] {
        try dbQueue.read { db in try Self.ordered.fetchAll(db) }
    }

    public func observation() -> ValueObservation<ValueReducers.Fetch<[RepositoryRecord]>> {
        ValueObservation.tracking { db in try Self.ordered.fetchAll(db) }
    }

    /// Adding a path that is already in the list returns the existing record
    /// instead of failing on the UNIQUE constraint, so "add" can simply
    /// select it. New repositories go to the end of the list, named after
    /// their folder.
    @discardableResult
    public func add(path: String) throws -> RepositoryRecord {
        try dbQueue.write { db in
            if let existing = try RepositoryRecord.filter(Column("path") == path).fetchOne(db) { return existing }
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM repositories") ?? 0
            let name = URL(fileURLWithPath: path).lastPathComponent
            let record = RepositoryRecord(path: path, name: name, sortOrder: next)
            try record.insert(db)
            return record
        }
    }

    public func remove(id: String) throws {
        try dbQueue.write { db in _ = try RepositoryRecord.deleteOne(db, key: id) }
    }

    private static let ordered = RepositoryRecord.order(Column("sort_order"), Column("name").collating(.localizedCaseInsensitiveCompare))
}

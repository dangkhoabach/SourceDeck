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
    /// A picture the user chose for the sidebar, as a square PNG; nil
    /// shows the initials.
    public var avatar: Data?

    public init(id: String = UUID().uuidString, path: String, name: String, sortOrder: Int, addedAt: Date = Date(),
                avatar: Data? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.sortOrder = sortOrder
        self.addedAt = addedAt
        self.avatar = avatar
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Up to two letters for the avatar, as Contacts does with a first and
    /// last name: the first letters of the first two words of the name.
    /// Words are split at anything not a letter or digit, and a single word
    /// at its capitals: "SourceDeck" "SD", "CaPheSuaDa" "CP",
    /// "iHub" "IH", "repo" "R".
    public var initials: String {
        var words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.count == 1 { words = Self.camelCaseWords(words[0]) }
        return words.prefix(2).compactMap(\.first).map { $0.uppercased() }.joined()
    }

    /// "CaPheSuaDa" → Ca, Phe, Ty, Map; "KTVina" stays one word.
    private static func camelCaseWords(_ word: String) -> [String] {
        var words = [""]
        var previous: Character?
        for character in word {
            if let previous, previous.isLowercase, character.isUppercase { words.append("") }
            words[words.count - 1].append(character)
            previous = character
        }
        return words
    }
}

extension RepositoryRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repositories"

    enum CodingKeys: String, CodingKey {
        case id, path, name
        case sortOrder = "sort_order"
        case addedAt = "added_at"
        case avatar
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

    /// The list now, then again after every change — without the caller
    /// needing GRDB.
    public func updates() -> AsyncThrowingStream<[RepositoryRecord], Error> {
        AsyncThrowingStream { continuation in
            let cancellable = observation().start(in: dbQueue, scheduling: .async(onQueue: Self.updatesQueue),
                                                  onError: { continuation.finish(throwing: $0) },
                                                  onChange: { continuation.yield($0) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
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

    /// An empty name puts the folder name back.
    public func rename(id: String, to name: String) throws {
        try dbQueue.write { db in
            guard var record = try RepositoryRecord.fetchOne(db, key: id) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.name = trimmed.isEmpty ? URL(fileURLWithPath: record.path).lastPathComponent : trimmed
            try record.update(db)
        }
    }

    /// nil puts the initials back.
    public func setAvatar(id: String, to avatar: Data?) throws {
        try dbQueue.write { db in
            guard var record = try RepositoryRecord.fetchOne(db, key: id) else { return }
            record.avatar = avatar
            try record.update(db)
        }
    }

    /// Same arguments as SwiftUI's `onMove`; every record is renumbered so
    /// the order stays a plain 0…n-1.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try dbQueue.write { db in
            var records = try Self.ordered.fetchAll(db)
            let moving = source.map { records[$0] }
            for index in source.sorted(by: >) { records.remove(at: index) }
            let insertAt = destination - source.count(where: { $0 < destination })
            records.insert(contentsOf: moving, at: insertAt)
            for (order, var record) in records.enumerated() where record.sortOrder != order {
                record.sortOrder = order
                try record.update(db)
            }
        }
    }

    /// Serial, so changes arrive in the order they happened.
    private static let updatesQueue = DispatchQueue(label: "SourceDeckCore.RepositoryStore.updates")

    private static let ordered = RepositoryRecord.order(Column("sort_order"), Column("name").collating(.localizedCaseInsensitiveCompare))
}

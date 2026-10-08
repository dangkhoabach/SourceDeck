import Foundation
import GRDB

/// One repository's unsent commit message (plan §5.4). Removing the
/// repository from the list removes its draft (ON DELETE CASCADE).
struct CommitDraftRecord: Codable, Equatable {
    var repositoryId: String
    var keyword: String
    /// `[CommitDraft.Line]` as JSON.
    var outlineJSON: String
    var rawText: String?
    var pushAfterCommit: Bool
    var updatedAt: Date
}

extension CommitDraftRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "commit_drafts"

    enum CodingKeys: String, CodingKey {
        case keyword
        case repositoryId = "repository_id"
        case outlineJSON = "outline_json"
        case rawText = "raw_text"
        case pushAfterCommit = "push_after_commit"
        case updatedAt = "updated_at"
    }
}

public struct CommitDraftStore: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// nil when the repository has no draft yet.
    public func draft(repositoryID: String) throws -> CommitDraft? {
        guard let record = try dbQueue.read({ db in try CommitDraftRecord.fetchOne(db, key: repositoryID) }) else { return nil }
        let lines = try JSONDecoder().decode([CommitDraft.Line].self, from: Data(record.outlineJSON.utf8))
        return CommitDraft(keyword: CommitKeyword(rawValue: record.keyword) ?? .update, lines: lines,
                           rawText: record.rawText, pushAfterCommit: record.pushAfterCommit)
    }

    public func save(_ draft: CommitDraft, repositoryID: String) throws {
        let outline = String(decoding: try JSONEncoder().encode(draft.lines), as: UTF8.self)
        let record = CommitDraftRecord(repositoryId: repositoryID, keyword: draft.keyword.rawValue, outlineJSON: outline,
                                       rawText: draft.rawText, pushAfterCommit: draft.pushAfterCommit, updatedAt: Date())
        try dbQueue.write { db in try record.save(db) }
    }
}

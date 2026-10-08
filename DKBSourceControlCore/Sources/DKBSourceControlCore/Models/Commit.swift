import Foundation

public struct Commit: Sendable, Equatable, Identifiable {
    public let oid: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let commitDate: Date
    /// `%D` decorations as git prints them: "HEAD -> main", "origin/main", "tag: v1.0".
    public let refs: [String]
    /// The raw message, trailing newlines removed.
    public let message: String

    public var id: String { oid }
    public var shortOID: String { String(oid.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    /// First line only. `%s` would join the whole first paragraph, which for
    /// the git-rule format (no blank line after the header) is every line.
    public var summary: String { String(message.prefix { $0 != "\n" }) }

    /// Everything after the first line.
    public var body: String {
        guard let newline = message.firstIndex(of: "\n") else { return "" }
        return String(message[message.index(after: newline)...]).trimmingCharacters(in: .newlines)
    }
}

/// A file a commit changed, from `diff-tree --name-status`.
public struct CommitFileChange: Sendable, Equatable, Identifiable {
    public let path: String
    public let originalPath: String?
    public let change: FileChange

    public var id: String { path }
}

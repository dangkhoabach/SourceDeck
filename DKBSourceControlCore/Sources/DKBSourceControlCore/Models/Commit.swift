import Foundation

public struct Commit: Sendable, Equatable, Identifiable {
    public let oid: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let commitDate: Date
    /// `%D` decorations as git prints them with `--decorate=full`:
    /// "HEAD -> refs/heads/main", "refs/remotes/origin/main", "tag: refs/tags/v1.0".
    public let refs: [String]
    /// The raw message, trailing newlines removed.
    public let message: String

    public var id: String { oid }
    public var shortOID: String { String(oid.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    /// First line only. `%s` would join the whole first paragraph, which for
    /// the git-rule format (no blank line after the header) is every line.
    public var summary: String { String(message.prefix { $0 != "\n" }) }

    /// What a list shows. A git-rule header ("+ Fix Bug +") says little on
    /// its own, so the first detail follows it: "Fix Bug · Fix login not
    /// returning token". Any other message shows its first line.
    public var title: String {
        let lines = message.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count > 1, lines[0].hasPrefix("+ "), lines[0].hasSuffix(" +"), lines[0].count > 4,
              lines[1].hasPrefix(" - ") else { return summary }
        return "\(lines[0].dropFirst(2).dropLast(2)) · \(lines[1].dropFirst(3))"
    }

    /// The refs pointing here, by kind. A remote's HEAD only points at its
    /// default branch, so it is left out.
    public var decorations: [CommitRef] {
        refs.compactMap { ref in
            if ref == "HEAD" { return CommitRef(kind: .detachedHead, name: "HEAD") }
            if ref.hasPrefix("HEAD -> ") { return CommitRef(kind: .head, name: CommitRef.shortName(ref.dropFirst("HEAD -> ".count))) }
            if ref.hasPrefix("tag: ") { return CommitRef(kind: .tag, name: CommitRef.shortName(ref.dropFirst("tag: ".count))) }
            if ref.hasPrefix("refs/remotes/") {
                return ref.hasSuffix("/HEAD") ? nil : CommitRef(kind: .remote, name: CommitRef.shortName(Substring(ref)))
            }
            return CommitRef(kind: .local, name: CommitRef.shortName(Substring(ref)))
        }
    }

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

/// A commit of one file's history, with the file as that commit changed
/// it: its name then, and the one before a rename.
public struct FileRevision: Sendable, Equatable, Identifiable {
    public let commit: Commit
    /// nil when git shows no change for it (a merge that took the file
    /// from its first parent).
    public internal(set) var file: CommitFileChange?

    public var id: String { commit.oid }
}

/// A branch or tag shown next to a commit in History.
public struct CommitRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The checked-out branch.
        case head
        /// HEAD with no branch.
        case detachedHead
        case local, remote, tag
    }

    public let kind: Kind
    /// "main", "origin/main", "v1.0".
    public let name: String

    static func shortName(_ ref: Substring) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return String(ref)
    }
}

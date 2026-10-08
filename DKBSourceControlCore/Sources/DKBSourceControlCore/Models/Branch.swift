import Foundation

public struct Branch: Sendable, Equatable, Identifiable {
    /// "main" or "origin/main".
    public let name: String
    public let isRemote: Bool
    public let oid: String
    /// Short name of the upstream, "origin/main".
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// The upstream was deleted on the remote (`[gone]`).
    public let upstreamGone: Bool
    public let isHead: Bool

    public var id: String { (isRemote ? "refs/remotes/" : "refs/heads/") + name }
}

public struct Stash: Sendable, Equatable, Identifiable {
    /// "stash@{0}".
    public let ref: String
    public let message: String
    public let date: Date

    public var id: String { ref }
}

/// `git remote get-url origin`, and where it is on the web when it is GitHub.
public struct RemoteURL: Sendable, Equatable {
    public let raw: String

    /// `https://github.com/owner/repo(.git)` and `git@github.com:owner/repo(.git)`.
    public var gitHubWebURL: URL? {
        let path: Substring
        if let range = raw.range(of: "github.com/") ?? raw.range(of: "github.com:") {
            path = raw[range.upperBound...]
        } else {
            return nil
        }
        let trimmed = path.hasSuffix(".git") ? path.dropLast(4) : path
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
    }
}

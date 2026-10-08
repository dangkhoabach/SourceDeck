import Foundation

/// One side (index or work tree) of a `git status` entry.
public enum FileChange: Sendable, Equatable {
    case unmodified, modified, typeChanged, added, deleted, renamed, copied, unmerged, untracked

    /// The porcelain letter: `.` M T A D R C U.
    init?(statusLetter: Character) {
        switch statusLetter {
        case ".": self = .unmodified
        case "M": self = .modified
        case "T": self = .typeChanged
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .unmerged
        default: return nil
        }
    }
}

public struct StatusEntry: Sendable, Equatable, Identifiable {
    public let path: String
    /// The path before a rename or copy.
    public let originalPath: String?
    public let index: FileChange
    public let workTree: FileChange
    public let isConflict: Bool

    public var id: String { path }
    public var isUntracked: Bool { index == .untracked }
    public var hasStagedChange: Bool { !isConflict && !isUntracked && index != .unmodified }
    public var hasUnstagedChange: Bool { isUntracked || (!isConflict && workTree != .unmodified) }

    public init(path: String, originalPath: String? = nil, index: FileChange, workTree: FileChange, isConflict: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.workTree = workTree
        self.isConflict = isConflict
    }
}

/// The `# branch.*` headers of `status --porcelain=v2 --branch`.
public struct BranchHead: Sendable, Equatable {
    /// nil on a branch with no commit yet.
    public let oid: String?
    /// nil when HEAD is detached.
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public var isUnborn: Bool { oid == nil }
    public var isDetached: Bool { branch == nil }
}

/// An operation git left half done; the work tree can't be committed
/// normally until it is finished or aborted (plan D17).
public enum RepositoryState: Sendable, Equatable {
    case normal, merging, rebasing, cherryPicking, reverting, bisecting

    /// The same order git's own `wt-status` checks them in.
    static func detect(gitDirectory: URL) -> RepositoryState {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_LOG") { return .bisecting }
        return .normal
    }

    /// The command that throws the operation away, back to where it started.
    var abortArguments: [String]? {
        switch self {
        case .normal: nil
        case .merging: ["merge", "--abort"]
        case .rebasing: ["rebase", "--abort"]
        case .cherryPicking: ["cherry-pick", "--abort"]
        case .reverting: ["revert", "--abort"]
        case .bisecting: ["bisect", "reset"]
        }
    }
}

public struct RepositoryStatus: Sendable, Equatable {
    public let head: BranchHead
    public let entries: [StatusEntry]
    public let state: RepositoryState

    public var hasConflicts: Bool { entries.contains(where: \.isConflict) }
    public var stagedCount: Int { entries.count(where: \.hasStagedChange) }
    public var unstagedCount: Int { entries.count(where: { $0.hasUnstagedChange && !$0.isUntracked }) }
    public var untrackedCount: Int { entries.count(where: \.isUntracked) }
    public var isClean: Bool { entries.isEmpty }
}

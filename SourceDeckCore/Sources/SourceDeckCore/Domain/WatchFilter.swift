import Foundation

/// Decides which FSEvents batches should refresh a repository.
///
/// Events name folders, not files. A build writes thousands of them, nearly
/// all under ignored folders (measured: 441 of 443 callbacks), and git
/// writes `.git/objects/` on every commit and fetch; neither changes what
/// the working copy shows. Everything else does, including the rest of
/// `.git` (index, HEAD, refs, MERGE_HEAD).
public struct WatchFilter: Sendable, Equatable {
    let root: String
    let objects: String
    var ignored: [String]

    /// - Parameters:
    ///   - root: the work tree's top level.
    ///   - gitDirectory: `.git`, or where a linked work tree's `.git` file points.
    ///   - ignoredDirectories: relative to `root`, as `GitRepository.ignoredDirectories()` lists them.
    public init(root: String, gitDirectory: String, ignoredDirectories: [String]) {
        self.root = Self.folder(root)
        objects = Self.folder(gitDirectory) + "objects/"
        ignored = []
        update(ignoredDirectories: ignoredDirectories)
    }

    /// A build can create a new ignored folder at any time, so the list is
    /// read again after each refresh.
    public mutating func update(ignoredDirectories: [String]) {
        ignored = ignoredDirectories.map { root + Self.folder($0) }
    }

    public func isRelevant(_ batch: [String]) -> Bool {
        batch.contains { path in
            let path = Self.folder(path)
            return !path.hasPrefix(objects) && !ignored.contains { path.hasPrefix($0) }
        }
    }

    /// With exactly one trailing "/", so "build/" never matches "builder/".
    static func folder(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

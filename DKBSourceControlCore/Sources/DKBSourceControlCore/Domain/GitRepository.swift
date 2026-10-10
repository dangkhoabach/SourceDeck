import Foundation

public struct OperationOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String = "", stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum DiffArea: Sendable, Equatable {
    /// Work tree against the index.
    case unstaged
    /// Index against HEAD.
    case staged
    /// A file git doesn't track yet, shown as all added.
    case untracked
    /// What a commit changed against its first parent.
    case commit(String)
}

/// How a diff is shown (plan F3). Only the default makes patches for
/// `git apply`: with whitespace ignored, the lines shown aren't the lines
/// in the file.
public struct DiffOptions: Sendable, Equatable {
    /// Lines of context around each change.
    public var context: Int
    public var ignoresWhitespace: Bool

    public init(context: Int = 3, ignoresWhitespace: Bool = false) {
        self.context = context
        self.ignoresWhitespace = ignoresWhitespace
    }

    /// As much context as git takes: the whole file in one hunk.
    public static let wholeFile = Int(Int32.max)

    var arguments: [String] {
        ["-U\(context)"] + (ignoresWhitespace ? ["--ignore-all-space"] : [])
    }
}

public enum PatchMode: Sendable {
    case stage, unstage, discard
}

public enum PullMode: String, Sendable, CaseIterable {
    case fastForwardOnly, rebase
}

/// `git reset --soft`, `--mixed` or `--hard`.
public enum ResetMode: String, Sendable, CaseIterable {
    case soft, mixed, hard
}

/// One work tree, and every git command the app runs in it (plan §5.3).
///
/// Writes run one at a time, in the order they were asked for: an actor
/// alone doesn't guarantee that (its async methods interleave at every
/// `await`), and two `git add` racing for `index.lock` would fail one of
/// them. Reads don't queue — they take no lock (`GIT_OPTIONAL_LOCKS=0`).
public actor GitRepository {
    public nonisolated let root: URL
    public nonisolated let git: GitProcess
    private var gitDirectory: URL?
    private var writeQueue: Task<Void, Never>?

    static let localTimeout = Duration.seconds(30)
    static let networkTimeout = Duration.seconds(120)
    /// A large repository takes minutes; the user can cancel any time.
    static let cloneTimeout = Duration.seconds(3600)
    static let lockRetryDelay = Duration.milliseconds(300)
    /// Fixed so the user's diff config can't change what the parser and
    /// `git apply` see: prefixes, colour, external tools, text conversion.
    /// Context and whitespace come from `DiffOptions`.
    static let diffOptions = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
    /// Paths from the file list are file names, never patterns: a file
    /// called "*.txt" or ":(exclude)x" must mean only itself. Given per
    /// command, not as `GIT_LITERAL_PATHSPECS` for every one: `stash push -u`
    /// relies on pathspec magic internally and stops clearing untracked
    /// files under it.
    static let literal = "--literal-pathspecs"
    /// A merge is shown against its first parent: what the merge brought in.
    static let firstParent = "--diff-merges=first-parent"

    public init(root: URL, git: GitProcess) {
        self.root = root
        self.git = git
    }

    /// The repository containing `url`, opened at its top level.
    public static func open(_ url: URL, git: GitProcess) async throws -> GitRepository {
        let arguments = ["rev-parse", "--show-toplevel"]
        let result = try await git.run(arguments, in: url, readOnly: true)
        guard result.succeeded else { throw GitCommandError(arguments: arguments, result: result) }
        let path = result.stdoutText.trimmingCharacters(in: .newlines)
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true), git: git)
    }

    /// Clones `url` (anything `git clone` takes: HTTPS, SSH, a local path)
    /// into `destination`, which must not exist yet or be an empty folder.
    /// When the clone fails or the task is cancelled, git removes the folder
    /// it created.
    public static func clone(_ url: String, into destination: URL, git: GitProcess) async throws -> OperationOutput {
        // After "--", a URL starting with "-" can't be read as an option.
        let arguments = ["clone", "--", url, destination.path]
        let result = try await git.run(arguments, in: destination.deletingLastPathComponent(), timeout: cloneTimeout)
        guard result.succeeded else { throw GitCommandError(arguments: arguments, result: result) }
        return OperationOutput(stdout: result.stdoutText, stderr: result.stderr)
    }

    /// The folder `git clone` would make for `url`: its last part without
    /// ".git", for HTTPS ("https://github.com/o/repo.git"), SSH
    /// ("git@github.com:o/repo.git") and local paths alike.
    public static func cloneFolderName(for url: String) -> String {
        var name = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".git") { name.removeLast(4) }
        while name.hasSuffix("/") { name.removeLast() }
        return String(name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
    }

    // MARK: - Reads

    public func status() async throws -> RepositoryStatus {
        let result = try await run(StatusParser.arguments, readOnly: true)
        let parsed = StatusParser.parse(result.stdout)
        let state = RepositoryState.detect(gitDirectory: try await gitDirectory())
        return RepositoryStatus(head: parsed.head, entries: parsed.entries, state: state)
    }

    public func branches() async throws -> [Branch] {
        BranchParser.parse(try await run(BranchParser.arguments, readOnly: true).stdout)
    }

    /// Newest first. `grep` and `author` match literally, case-insensitively.
    /// A branch with no commit yet has no history rather than an error.
    public func log(revision: String = "HEAD", path: String? = nil, grep: String? = nil, author: String? = nil,
                    limit: Int = 200, skip: Int = 0) async throws -> [Commit] {
        try Self.requireArgument(revision)
        // Full ref names, so a local branch can be told from a remote one.
        var arguments = ["log", "-z", "--decorate=full", LogParser.format, "--max-count=\(limit)", "--skip=\(skip)"]
        if grep != nil || author != nil { arguments += ["--fixed-strings", "--regexp-ignore-case"] }
        if let grep { arguments.append("--grep=\(grep)") }
        if let author { arguments.append("--author=\(author)") }
        arguments.append(revision)
        if let path { arguments = [Self.literal] + arguments + ["--", path] }
        do {
            return LogParser.parse(try await run(arguments, readOnly: true).stdout)
        } catch let error as GitCommandError where revision == "HEAD" {
            if try await hasHead() { throw error }
            return []
        }
    }

    /// The commits that changed one file, newest first, followed through
    /// renames; each with the file's name at that commit. A merge is
    /// compared with its first parent, as in `commitFiles`.
    ///
    /// `--skip` with `--follow` skips commits before keeping the file's
    /// (git 2.54), so a later page reads the earlier ones again and drops them.
    public func fileHistory(path: String, limit: Int = 200, skip: Int = 0) async throws -> [FileRevision] {
        let arguments = [Self.literal, "log", "-z", "--follow", "--name-status", "-M", Self.firstParent, "--decorate=full",
                         FileHistoryParser.format, "--max-count=\(skip + limit)", "HEAD", "--", path]
        do {
            return Array(FileHistoryParser.parse(try await run(arguments, readOnly: true).stdout).dropFirst(skip))
        } catch let error as GitCommandError {
            if try await hasHead() { throw error }
            return []
        }
    }

    /// How many commits resetting to `oid` takes off the branch, and how
    /// many of those no remote-tracking branch has: the rest were pushed.
    public func commitsAfter(_ oid: String) async throws -> (total: Int, notOnRemote: Int) {
        try Self.requireArgument(oid)
        func count(_ arguments: [String]) async throws -> Int {
            Int(try await run(["rev-list", "--count"] + arguments, readOnly: true).stdoutText
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return (try await count(["\(oid)..HEAD"]), try await count(["\(oid)..HEAD", "--not", "--remotes"]))
    }

    /// Files a commit changed; a merge is compared with its first parent.
    public func commitFiles(_ oid: String) async throws -> [CommitFileChange] {
        try Self.requireArgument(oid)
        let arguments = ["diff-tree", "--no-commit-id", "--root", "-r", "-M", "-z", "--name-status", Self.firstParent, oid]
        return NameStatusParser.parse(try await run(arguments, readOnly: true).stdout)
    }

    /// nil when there is nothing to show (the change was undone meanwhile).
    /// A rename needs both paths, or git shows it as an added file.
    public func diff(path: String, originalPath: String? = nil, area: DiffArea,
                     options: DiffOptions = DiffOptions()) async throws -> DiffFile? {
        let paths = [originalPath, path].compactMap { $0 }
        let diffOptions = Self.diffOptions + options.arguments
        let arguments: [String]
        var allowed: Set<Int32> = [0]
        switch area {
        case .unstaged:
            arguments = [Self.literal, "diff"] + diffOptions + ["--"] + paths
        case .staged:
            arguments = [Self.literal, "diff", "--cached"] + diffOptions + ["--"] + paths
        case .untracked:
            // Exit code 1 means "there are differences" here, the normal case.
            arguments = ["diff", "--no-index"] + diffOptions + ["--", "/dev/null", path]
            allowed = [0, 1]
        case .commit(let oid):
            try Self.requireArgument(oid)
            arguments = [Self.literal, "show", "--format=", Self.firstParent] + diffOptions + [oid, "--"] + paths
        }
        let result = try await run(arguments, readOnly: true, allowedExitCodes: allowed)
        return DiffParser.parse(result.stdoutText).first
    }

    /// Every staged change, for the sensitive check before a commit (plan
    /// F4b). No line limit: a secret in a long file must still be found.
    public func stagedDiff() async throws -> [DiffFile] {
        let arguments = ["diff", "--cached"] + Self.diffOptions + DiffOptions().arguments
        return DiffParser.parse(try await run(arguments, readOnly: true).stdoutText, maxLines: .max)
    }

    /// Whether a remote-tracking branch already contains HEAD: amending it
    /// would then rewrite history others may have (plan D9).
    public func isHeadOnRemote() async throws -> Bool {
        guard try await hasHead() else { return false }
        let arguments = ["for-each-ref", "--contains=HEAD", "--count=1", "--format=%(refname)", "refs/remotes"]
        return !(try await run(arguments, readOnly: true).stdout.isEmpty)
    }

    /// Folders an ignore rule matches itself (`build/`, `node_modules/`),
    /// relative to the root and ending in "/", for the watcher (plan D10).
    /// Not `ls-files --ignored --directory`: it also lists a folder that
    /// only holds ignored files, though a new file there would be untracked.
    public func ignoredDirectories() async throws -> [String] {
        let arguments = ["status", "--porcelain=v2", "-z", "--ignored=matching", "--untracked-files=normal"]
        return try await run(arguments, readOnly: true).stdout.nullSeparatedFields().compactMap { field in
            field.hasPrefix("! ") && field.hasSuffix("/") ? String(field.dropFirst(2)) : nil
        }
    }

    public func stashes() async throws -> [Stash] {
        StashParser.parse(try await run(StashParser.arguments, readOnly: true).stdout)
    }

    /// nil when the repository has no remote of that name.
    public func remoteURL(_ name: String = "origin") async throws -> RemoteURL? {
        try Self.requireArgument(name)
        let result = try await run(["remote", "get-url", name], readOnly: true, allowedExitCodes: [0, 2])
        let url = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !url.isEmpty ? RemoteURL(raw: url) : nil
    }

    /// Every fetch and push address of every remote, once each, as
    /// `git remote -v` shows them (`insteadOf` and `pushurl` applied): the
    /// hosts Settings › Accounts lists.
    public func remoteURLs() async throws -> [String] {
        var urls: [String] = []
        for line in try await run(["remote", "-v"], readOnly: true).stdoutText.split(separator: "\n") {
            // "origin\thttps://host/repo.git (fetch)"
            guard let tab = line.firstIndex(of: "\t"), let space = line.lastIndex(of: " "), space > tab else { continue }
            let url = String(line[line.index(after: tab)..<space])
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    // MARK: - Writes

    public func stage(_ paths: [String]) async throws -> OperationOutput {
        try await write([Self.literal, "add", "-A", "--"] + paths)
    }

    /// Before the first commit there is no HEAD to restore the index from,
    /// so the paths are removed from the index instead. A staged rename
    /// needs both paths, or the old one stays staged as deleted.
    public func unstage(_ paths: [String]) async throws -> OperationOutput {
        let command = try await hasHead() ? ["restore", "--staged", "--"] : ["rm", "--cached", "-r", "-q", "--"]
        return try await write([Self.literal] + command + paths)
    }

    public func unstageAll() async throws -> OperationOutput {
        try await write(["reset", "-q"])
    }

    public func applyPatch(_ patch: String, mode: PatchMode) async throws -> OperationOutput {
        let options: [String] = switch mode {
        case .stage: ["--cached"]
        case .unstage: ["--cached", "--reverse"]
        case .discard: ["--reverse"]
        }
        return try await write(["apply"] + options + ["--whitespace=nowarn", "-"], stdin: Data(patch.utf8))
    }

    /// Tracked files only: untracked and newly added files go to the Trash
    /// from the app instead (plan D15), never through git.
    /// - Parameter includingStaged: also throw away what is staged.
    public func discard(_ paths: [String], includingStaged: Bool) async throws -> OperationOutput {
        let options = includingStaged ? ["--source=HEAD", "--staged", "--worktree"] : ["--worktree"]
        return try await write([Self.literal, "restore"] + options + ["--"] + paths)
    }

    /// The message goes through stdin; `--cleanup=whitespace` keeps the
    /// leading spaces of the git-rule format and lines starting with "#"
    /// (plan D9). Hooks run.
    public func commit(_ message: String, amend: Bool = false) async throws -> OperationOutput {
        try await write(["commit", "-F", "-", "--cleanup=whitespace"] + (amend ? ["--amend"] : []), stdin: Data(message.utf8))
    }

    public func fetch() async throws -> OperationOutput {
        try await write(["fetch", "--prune"], timeout: Self.networkTimeout)
    }

    /// Never creates a merge commit on the user's behalf (plan D13).
    public func pull(mode: PullMode) async throws -> OperationOutput {
        try await write(["pull", mode == .rebase ? "--rebase" : "--ff-only"], timeout: Self.networkTimeout)
    }

    /// No force option exists (plan D14). `setUpstream` is the branch to
    /// publish when it has no upstream yet.
    public func push(setUpstream branch: String? = nil) async throws -> OperationOutput {
        if let branch {
            try Self.requireArgument(branch)
            return try await write(["push", "--porcelain", "-u", "origin", branch], timeout: Self.networkTimeout)
        }
        return try await write(["push", "--porcelain", "origin", "HEAD"], timeout: Self.networkTimeout)
    }

    public func switchBranch(_ name: String) async throws -> OperationOutput {
        try Self.requireArgument(name)
        return try await write(["switch", name])
    }

    public func createBranch(_ name: String) async throws -> OperationOutput {
        try Self.requireArgument(name)
        return try await write(["switch", "-c", name])
    }

    /// `-d` only: git refuses to delete a branch whose commits exist nowhere else.
    public func deleteBranch(_ name: String) async throws -> OperationOutput {
        try Self.requireArgument(name)
        return try await write(["branch", "-d", name])
    }

    /// Untracked files are stashed too. An empty message lets git name it
    /// ("WIP on main: …").
    public func stashPush(message: String) async throws -> OperationOutput {
        try await write(["stash", "push", "--include-untracked"] + (message.isEmpty ? [] : ["--message=\(message)"]))
    }

    public func stashPop(_ stash: Stash) async throws -> OperationOutput {
        try await write(["stash", "pop", stash.ref])
    }

    public func stashDrop(_ stash: Stash) async throws -> OperationOutput {
        try await write(["stash", "drop", stash.ref])
    }

    /// The opposite of `commit`'s changes, staged and not committed: the
    /// app's commits go through the composer (git-rule), never git's
    /// `Revert "…"`. Leaves `REVERT_HEAD`, which the commit clears; a
    /// conflict stops there as a revert in progress. A merge is undone
    /// against its first parent, as History shows it.
    public func revert(_ commit: Commit) async throws -> OperationOutput {
        try Self.requireArgument(commit.oid)
        return try await write(["revert", "--no-commit"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.oid])
    }

    /// Moves the current branch (or a detached HEAD) to `oid`. `.hard` also
    /// throws away every uncommitted change to tracked files: the caller
    /// stashes them first.
    public func reset(to oid: String, mode: ResetMode) async throws -> OperationOutput {
        try Self.requireArgument(oid)
        return try await write(["reset", "--\(mode.rawValue)", oid])
    }

    /// Throws away the merge, rebase, cherry-pick, revert or bisect in progress.
    public func abortInProgress() async throws -> OperationOutput {
        let state = RepositoryState.detect(gitDirectory: try await gitDirectory())
        guard let arguments = state.abortArguments else { return OperationOutput(stdout: "", stderr: "") }
        return try await write(arguments)
    }

    // MARK: - Running

    @discardableResult
    private func run(_ arguments: [String], stdin: Data? = nil, readOnly: Bool, timeout: Duration = localTimeout,
                     allowedExitCodes: Set<Int32> = [0]) async throws -> GitResult {
        let result = try await git.run(arguments, in: root, stdin: stdin, readOnly: readOnly, timeout: timeout)
        guard allowedExitCodes.contains(result.exitCode) else { throw GitCommandError(arguments: arguments, result: result) }
        return result
    }

    /// Queued behind every write asked for before it. The queue is set up
    /// before the first `await`, so call order is run order.
    ///
    /// Another tool (Sourcetree, VS Code) holding `index.lock` usually lets
    /// go within moments, so a locked index is tried once more after
    /// `lockRetryDelay` (plan R6). git checks the lock before changing
    /// anything, so the first attempt left nothing half done.
    private func write(_ arguments: [String], stdin: Data? = nil, timeout: Duration = localTimeout) async throws -> OperationOutput {
        let previous = writeQueue
        let operation = Task {
            await previous?.value
            do {
                return try await self.run(arguments, stdin: stdin, readOnly: false, timeout: timeout)
            } catch let error as GitCommandError where error.kind == .indexLocked {
                try await Task.sleep(for: Self.lockRetryDelay)
                return try await self.run(arguments, stdin: stdin, readOnly: false, timeout: timeout)
            }
        }
        writeQueue = Task { _ = try? await operation.value }
        let result = try await operation.value
        return OperationOutput(stdout: result.stdoutText, stderr: result.stderr)
    }

    private func hasHead() async throws -> Bool {
        try await run(["rev-parse", "--verify", "--quiet", "HEAD"], readOnly: true, allowedExitCodes: [0, 1]).succeeded
    }

    /// `.git`, or wherever a linked work tree's `.git` file points.
    public func gitDirectory() async throws -> URL {
        if let gitDirectory { return gitDirectory }
        let path = try await run(["rev-parse", "--absolute-git-dir"], readOnly: true).stdoutText
            .trimmingCharacters(in: .newlines)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        gitDirectory = url
        return url
    }

    /// A branch, revision or remote name starting with "-" would be read as
    /// an option. git refuses such names anyway; this makes sure it never
    /// gets the chance to interpret one.
    static func requireArgument(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-") else { throw GitRepositoryError.invalidArgument(value) }
    }
}

public enum GitRepositoryError: Error, Equatable, Sendable {
    case invalidArgument(String)
}

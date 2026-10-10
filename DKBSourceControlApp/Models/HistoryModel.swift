import AppKit
import DKBSourceControlCore
import Foundation
import Observation

/// History of one repository (plan F6): commits newest first, 200 at a
/// time, searched by message, author or path through git itself, or the
/// history of one file; the selected commit's files and the diff of one of
/// them; any branch's history, or every branch's, drawn as a graph;
/// reverting, cherry-picking or checking out a commit and resetting the
/// branch to one.
@MainActor
@Observable
final class HistoryModel {
    enum SearchScope: Hashable, CaseIterable {
        case message, author, path
    }

    /// Whose history the list shows.
    enum Revision: Hashable {
        case head
        case branch(String)
        /// Every local and remote branch and tag, and HEAD.
        case allBranches
    }

    unowned let model: RepositoryModel
    private(set) var commits: [Commit] = []
    /// Each commit's row of the graph, by SHA; empty while searching or in
    /// a file's history, where the list leaves commits out.
    private(set) var graph: [String: CommitGraph.Row] = [:]
    /// The widest row, so every row's graph takes the same width.
    private(set) var graphWidth = 0
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var loadError: Error?
    var search = ""
    var scope: SearchScope = .message
    var selection: String?
    private(set) var files: [CommitFileChange] = []
    var selectedFile: String?
    /// Folders closed in the tree layout; kept from one commit to the next.
    var collapsedFolders: Set<String> = []
    private(set) var fileDiff: DiffFile?
    /// The commit `files` belong to, and the commit and file `fileDiff`
    /// shows: until they match the selection, it is being read.
    private(set) var filesCommit: String?
    private(set) var fileDiffKey: String?
    /// The file whose history the list shows instead of every commit,
    /// followed through renames (plan: history actions §3.3).
    private(set) var filePath: String?
    var revision: Revision = .head
    /// The commit Reset… was asked for, while its sheet is up.
    var pendingReset: Commit?
    /// Create Branch Here… and Create Tag Here…, while their alerts are up.
    var pendingBranch: Commit?
    var pendingTag: Commit?
    /// A checkout waiting on uncommitted changes: stash them first, or cancel.
    var pendingCheckout: Commit?
    /// Selected once a load brings it in (from Blame).
    @ObservationIgnored private var pendingSelection: String?
    /// The file as each commit of `filePath`'s history changed it: its name then.
    @ObservationIgnored private var fileChanges: [String: CommitFileChange] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedQuery: Query?

    static let pageSize = 200

    /// What the list was read for; a change reads it from the top again.
    struct Query: Equatable {
        let search: String
        let scope: SearchScope
        let file: String?
        let revision: Revision
    }

    init(model: RepositoryModel) {
        self.model = model
    }

    var selectedCommit: Commit? {
        commits.first { $0.oid == selection }
    }

    /// The first page again, as many commits as were shown (after a commit,
    /// a fetch or a new search). A new search waits for typing to pause.
    func reload() async {
        let query = Query(search: search.trimmingCharacters(in: .whitespaces), scope: scope, file: filePath, revision: revision)
        // Another branch or file: the old list would pass for it meanwhile.
        if let loadedQuery, loadedQuery.file != query.file || loadedQuery.revision != query.revision {
            commits = []
            reachedEnd = false
        }
        if let loadedQuery, loadedQuery.search != query.search {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        let count = loadedQuery == query ? max(commits.count, Self.pageSize) : Self.pageSize
        await load(query, skip: 0, limit: count)
    }

    /// When the end of the list comes on screen.
    func loadMore() async {
        guard !isLoading, !reachedEnd, let loadedQuery else { return }
        await load(loadedQuery, skip: commits.count, limit: Self.pageSize)
    }

    private func load(_ query: Query, skip: Int, limit: Int) async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let text = query.search.isEmpty ? nil : query.search
            let page: [Commit]
            var changes: [String: CommitFileChange] = [:]
            // A file's history is HEAD's when every branch is shown.
            let branch = if case .branch(let name) = query.revision { name } else { "HEAD" }
            if let file = query.file {
                let revisions = try await model.repository.fileHistory(path: file, revision: branch, limit: limit, skip: skip)
                page = revisions.map(\.commit)
                for revision in revisions { changes[revision.id] = revision.file }
            } else {
                page = try await model.repository.log(revision: branch, allBranches: query.revision == .allBranches,
                                                      path: query.scope == .path ? text : nil,
                                                      grep: query.scope == .message ? text : nil,
                                                      author: query.scope == .author ? text : nil,
                                                      limit: limit, skip: skip)
            }
            guard current == generation else { return }
            fileChanges = skip == 0 ? changes : fileChanges.merging(changes) { $1 }
            commits = skip == 0 ? page : commits + page
            let rows = query.file == nil && text == nil ? CommitGraph.layout(commits) : []
            graph = Dictionary(uniqueKeysWithValues: zip(commits.map(\.oid), rows))
            graphWidth = rows.map(\.width).max() ?? 0
            if let pendingSelection, commits.contains(where: { $0.oid == pendingSelection }) {
                selection = pendingSelection
                self.pendingSelection = nil
            }
            reachedEnd = page.count < limit
            loadedQuery = query
            loadError = nil
            if let selection, !commits.contains(where: { $0.oid == selection }) { self.selection = nil }
        } catch {
            guard current == generation else { return }
            loadError = error
        }
    }

    /// The files of the selected commit; a merge against its first parent.
    func loadFiles() async {
        guard let oid = selection else {
            files = []
            filesCommit = nil
            selectedFile = nil
            return
        }
        let loaded = (try? await model.repository.commitFiles(oid)) ?? []
        guard !Task.isCancelled, selection == oid else { return }
        files = loaded
        filesCommit = oid
        // In a file's history, that file, by its name at this commit.
        if let path = fileChanges[oid]?.path, loaded.contains(where: { $0.path == path }) {
            selectedFile = path
        } else if let selectedFile, !loaded.contains(where: { $0.path == selectedFile }) {
            self.selectedFile = nil
        }
    }

    var isLoadingFiles: Bool { selection != nil && selection != filesCommit }
    var isLoadingFileDiff: Bool { selectedFile != nil && !isLoadingFiles && fileDiffKey != Self.diffKey(selection, selectedFile) }

    func loadFileDiff() async {
        guard let oid = selection, let path = selectedFile, let file = files.first(where: { $0.path == path }) else {
            fileDiff = nil
            fileDiffKey = nil
            return
        }
        let diff = try? await model.repository.diff(path: file.path, originalPath: file.originalPath, area: .commit(oid),
                                                    options: model.workingCopy.diffOptions)
        guard !Task.isCancelled else { return }
        fileDiff = diff
        fileDiffKey = Self.diffKey(oid, path)
    }

    private static func diffKey(_ commit: String?, _ path: String?) -> String {
        "\(commit ?? "")\u{0}\(path ?? "")"
    }

    /// Every commit that changed `path`, from a file's menu.
    func showHistory(of path: String) {
        filePath = path
        model.tab = .history
    }

    func showAllHistory() {
        filePath = nil
    }

    /// A line's commit from Blame, in the history of its file.
    func showCommit(_ oid: String, inHistoryOf path: String) {
        showHistory(of: path)
        if commits.contains(where: { $0.oid == oid }) {
            selection = oid
        } else {
            pendingSelection = oid
        }
    }

    /// The file as `commit` left it, in the working copy and not staged
    /// (plan: history actions §3.5). Offered only while the file has no
    /// uncommitted change, so nothing of the user's is replaced.
    func restore(_ file: CommitFileChange, from commit: Commit) async {
        let repository = model.repository
        let restored = await model.write("git restore --source=\(commit.shortOID) --worktree -- \(file.path)", logsSuccess: true) {
            try await repository.restore(file.path, from: commit.oid)
        }
        if restored { model.tab = .workingCopy }
    }

    /// A read-only copy in the temp folder, opened with its app.
    func open(_ file: CommitFileChange, at commit: Commit) async {
        let repository = model.repository
        await model.write("git cat-file blob \(commit.shortOID):\(file.path)") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DKB Source Control/\(commit.shortOID)", isDirectory: true)
            let url = folder.appendingPathComponent((file.path as NSString).lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try await repository.fileContents(file.path, at: commit.oid).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            return OperationOutput()
        }
    }

    /// Saved wherever the user picks.
    func save(_ file: CommitFileChange, at commit: Commit) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (file.path as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let repository = model.repository
        await model.write("git cat-file blob \(commit.shortOID):\(file.path)") {
            try await repository.fileContents(file.path, at: commit.oid).write(to: url)
            return OperationOutput()
        }
    }

    /// A branch's history, from its menu in Branches.
    func showHistory(of branch: Branch) {
        revision = branch.isHead ? .head : .branch(branch.name)
        filePath = nil
        model.tab = .history
    }

    /// Staged or modified tracked files would travel along or block the
    /// checkout, so the user is asked to stash them first, as for a branch.
    func requestCheckout(_ commit: Commit) async {
        if let status = model.status, status.stagedCount + status.unstagedCount > 0 {
            pendingCheckout = commit
            return
        }
        await checkout(commit)
    }

    func checkout(_ commit: Commit, stashingFirst: Bool = false) async {
        let repository = model.repository
        if stashingFirst {
            let stashed = await model.write("git stash push --include-untracked", logsSuccess: true) {
                try await repository.stashPush(message: "Before checking out \(commit.shortOID)")
            }
            guard stashed else { return }
        }
        await model.write("git switch --detach \(commit.shortOID)", logsSuccess: true) { try await repository.checkout(commit.oid) }
    }

    /// Committed by git with the commit's own message. A conflict stops
    /// as a cherry-pick in progress; the composer gets that message to
    /// finish it with once the conflicts are resolved.
    func cherryPick(_ commit: Commit) async {
        let repository = model.repository
        let picked = await model.write("git cherry-pick\(commit.isMerge ? " -m 1" : "") \(commit.shortOID)", logsSuccess: true) {
            try await repository.cherryPick(commit)
        }
        guard !picked, model.status?.state == .cherryPicking else { return }
        model.composer.use(commit.message)
        model.tab = .workingCopy
    }

    /// The opposite of `commit`, staged; the composer gets a message to
    /// finish in git-rule form (plan: history actions §3.1). A conflict
    /// leaves a revert in progress, with its banner and Abort.
    func revert(_ commit: Commit) async {
        let repository = model.repository
        let reverted = await model.write("git revert --no-commit\(commit.isMerge ? " -m 1" : "") \(commit.shortOID)",
                                         logsSuccess: true) {
            try await repository.revert(commit)
        }
        guard reverted || model.status?.state == .reverting else { return }
        model.composer.use("+ Update +\n - Revert \(commit.shortOID): \(commit.title)")
        model.tab = .workingCopy
    }

    /// Moves the branch to `commit` (plan: history actions §3.2). `.hard`
    /// stashes every change first, untracked files too, and doesn't reset
    /// when that fails. The log keeps where HEAD was.
    func reset(to commit: Commit, mode: ResetMode) async {
        let repository = model.repository
        if mode == .hard {
            let stashed = await model.write("git stash push --include-untracked", logsSuccess: true) {
                // Stored in the repository, so in English like its commits.
                try await repository.stashPush(message: "Before resetting to \(commit.shortOID)")
            }
            guard stashed else { return }
        }
        let previous = model.status?.head.oid.map { " (HEAD was \($0.prefix(7)))" } ?? ""
        await model.write("git reset --\(mode.rawValue) \(commit.shortOID)\(previous)", logsSuccess: true) {
            try await repository.reset(to: commit.oid, mode: mode)
        }
    }

    /// The commit's page on GitHub, when the remote is there.
    func webURL(of commit: Commit) -> URL? {
        model.gitHubURL?.appendingPathComponent("commit/\(commit.oid)")
    }
}

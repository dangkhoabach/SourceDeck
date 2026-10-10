import DKBSourceControlCore
import Foundation
import Observation

/// History of one repository (plan F6): commits newest first, 200 at a
/// time, searched by message, author or path through git itself, or the
/// history of one file; the selected commit's files and the diff of one of
/// them; reverting a commit and resetting the branch to one.
@MainActor
@Observable
final class HistoryModel {
    enum SearchScope: Hashable, CaseIterable {
        case message, author, path
    }

    unowned let model: RepositoryModel
    private(set) var commits: [Commit] = []
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
    /// The file whose history the list shows instead of every commit,
    /// followed through renames (plan: history actions §3.3).
    private(set) var filePath: String?
    /// The commit Reset… was asked for, while its sheet is up.
    var pendingReset: Commit?
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
        let query = Query(search: search.trimmingCharacters(in: .whitespaces), scope: scope, file: filePath)
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
            if let file = query.file {
                let revisions = try await model.repository.fileHistory(path: file, limit: limit, skip: skip)
                page = revisions.map(\.commit)
                for revision in revisions { changes[revision.id] = revision.file }
            } else {
                page = try await model.repository.log(path: query.scope == .path ? text : nil,
                                                      grep: query.scope == .message ? text : nil,
                                                      author: query.scope == .author ? text : nil,
                                                      limit: limit, skip: skip)
            }
            guard current == generation else { return }
            fileChanges = skip == 0 ? changes : fileChanges.merging(changes) { $1 }
            commits = skip == 0 ? page : commits + page
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
            selectedFile = nil
            return
        }
        let loaded = (try? await model.repository.commitFiles(oid)) ?? []
        guard !Task.isCancelled, selection == oid else { return }
        files = loaded
        // In a file's history, that file, by its name at this commit.
        if let path = fileChanges[oid]?.path, loaded.contains(where: { $0.path == path }) {
            selectedFile = path
        } else if let selectedFile, !loaded.contains(where: { $0.path == selectedFile }) {
            self.selectedFile = nil
        }
    }

    func loadFileDiff() async {
        guard let oid = selection, let path = selectedFile, let file = files.first(where: { $0.path == path }) else {
            fileDiff = nil
            return
        }
        let diff = try? await model.repository.diff(path: file.path, originalPath: file.originalPath, area: .commit(oid),
                                                    options: model.workingCopy.diffOptions)
        guard !Task.isCancelled else { return }
        fileDiff = diff
    }

    /// Every commit that changed `path`, from a file's menu.
    func showHistory(of path: String) {
        filePath = path
        model.tab = .history
    }

    func showAllHistory() {
        filePath = nil
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

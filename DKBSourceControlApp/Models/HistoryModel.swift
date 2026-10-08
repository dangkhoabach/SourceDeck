import DKBSourceControlCore
import Foundation
import Observation

/// History of one repository (plan F6): commits newest first, 200 at a
/// time, searched by message, author or path through git itself; the
/// selected commit's files and the diff of one of them.
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
    private(set) var fileDiff: DiffFile?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadedQuery: Query?

    static let pageSize = 200

    /// What the list was read for; a change reads it from the top again.
    struct Query: Equatable {
        let search: String
        let scope: SearchScope
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
        let query = Query(search: search.trimmingCharacters(in: .whitespaces), scope: scope)
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
            let page = try await model.repository.log(path: query.scope == .path ? text : nil,
                                                      grep: query.scope == .message ? text : nil,
                                                      author: query.scope == .author ? text : nil,
                                                      limit: limit, skip: skip)
            guard current == generation else { return }
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
        if let selectedFile, !loaded.contains(where: { $0.path == selectedFile }) { self.selectedFile = nil }
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

    /// The commit's page on GitHub, when the remote is there.
    func webURL(of commit: Commit) -> URL? {
        model.gitHubURL?.appendingPathComponent("commit/\(commit.oid)")
    }
}

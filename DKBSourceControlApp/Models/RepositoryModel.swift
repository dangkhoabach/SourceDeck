import DKBSourceControlCore
import Foundation
import Observation

/// One repository of the list: its last known state, the remote operation
/// running on it, if any, and every write the app makes in it.
@MainActor
@Observable
final class RepositoryModel: Identifiable {
    /// ⌘1 / ⌘2 / ⌘3 (plan §7.2).
    enum Tab: Hashable, CaseIterable {
        case workingCopy, history, branches
    }

    enum RemoteOperation {
        case fetch, pull, push

        var command: String {
            switch self {
            case .fetch: "git fetch --prune"
            case .pull: "git pull"
            case .push: "git push"
            }
        }
    }

    private(set) var record: RepositoryRecord
    let repository: GitRepository
    private(set) var status: RepositoryStatus?
    private(set) var lastCommit: Commit?
    private(set) var gitHubURL: URL?
    /// Why the last refresh failed: folder moved or deleted, not a repository.
    private(set) var refreshError: Error?
    private(set) var isRefreshing = false
    private(set) var runningOperation: RemoteOperation?
    /// The last failed write or remote operation, until the next one succeeds.
    private(set) var operationError: Error?
    /// Counts finished refreshes, so a diff on screen reloads even when the
    /// status reads the same (a file edited again stays "M").
    private(set) var refreshCount = 0
    /// A branch with no upstream, waiting for the user to confirm its first
    /// push (plan D14).
    var pendingPublish: String?
    var tab: Tab = .workingCopy
    @ObservationIgnored private var remoteLoaded = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var watchFilter: WatchFilter?
    @ObservationIgnored private var watchRefresh: Task<Void, Never>?
    @ObservationIgnored private var lastWatchRefresh = ContinuousClock.now - .seconds(1)
    @ObservationIgnored private let log: OperationLog
    @ObservationIgnored let drafts: CommitDraftStore
    /// Kept per repository, so the selection and the half-written message
    /// are still there after looking at another one.
    @ObservationIgnored private(set) lazy var workingCopy = WorkingCopyModel(model: self)
    @ObservationIgnored private(set) lazy var history = HistoryModel(model: self)
    @ObservationIgnored private(set) lazy var branches = BranchesModel(model: self)
    @ObservationIgnored private var openedComposer: CommitComposer?

    /// Made the first time the repository is shown, reading its draft then.
    var composer: CommitComposer {
        if let openedComposer { return openedComposer }
        let composer = CommitComposer(model: self)
        openedComposer = composer
        return composer
    }

    /// The record's id, which never changes; readable from any isolation
    /// as `Identifiable` requires.
    nonisolated let id: String
    var folderExists: Bool { FileManager.default.fileExists(atPath: record.path) }

    init(record: RepositoryRecord, git: GitProcess, log: OperationLog, drafts: CommitDraftStore) {
        self.record = record
        id = record.id
        repository = GitRepository(root: record.url, git: git)
        self.log = log
        self.drafts = drafts
    }

    func update(_ record: RepositoryRecord) {
        self.record = record
    }

    /// Status and last commit, read together (~25 ms, PoC 0.1). Asked for
    /// while one is running, it runs once more after it instead of in
    /// parallel — the running one may have read the state before the change
    /// that prompted the new request.
    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await load()
        } while refreshAgain
        isRefreshing = false
        refreshCount += 1
    }

    private func load() async {
        guard folderExists else {
            status = nil
            refreshError = CocoaError(.fileNoSuchFile)
            return
        }
        do {
            async let status = repository.status()
            async let commits = repository.log(limit: 1)
            self.status = try await status
            lastCommit = try await commits.first
            refreshError = nil
            if !remoteLoaded {
                gitHubURL = try? await repository.remoteURL()?.gitHubWebURL
                remoteLoaded = true
            }
        } catch {
            refreshError = error
        }
    }

    /// The last keystrokes, which the composer saves half a second late.
    func saveDraft() {
        openedComposer?.saveNow()
    }

    func dismissOperationError() {
        operationError = nil
    }

    /// - Parameter setUpstream: for a push, the branch to publish when it
    ///   has no upstream yet.
    func run(_ operation: RemoteOperation, setUpstream: String? = nil) async {
        guard runningOperation == nil else { return }
        runningOperation = operation
        await write(operation.command, logsSuccess: true) { [repository] in
            switch operation {
            case .fetch: try await repository.fetch()
            case .pull: try await repository.pull(mode: AppSettings.pullMode)
            case .push: try await repository.push(setUpstream: setUpstream)
            }
        }
        runningOperation = nil
    }

    /// Push, asking first when the branch was never published (plan D14).
    func push() async {
        if let head = status?.head, head.upstream == nil, let branch = head.branch, !head.isUnborn {
            pendingPublish = branch
            return
        }
        await run(.push)
    }

    /// Runs one write, then refreshes; the watcher stays quiet meanwhile,
    /// since that refresh shows the result (plan D10). A failure goes to
    /// the log and the banner; a success only goes to the log when its
    /// output matters (`logsSuccess`: commit hooks, push, discards).
    /// - Returns: whether it succeeded.
    @discardableResult
    func write(_ command: String, logsSuccess: Bool = false, _ body: () async throws -> OperationOutput) async -> Bool {
        writesInFlight += 1
        let started = Date()
        let entry = logsSuccess ? log.start(repository: record.name, command: command) : nil
        var succeeded = false
        do {
            let output = try await body()
            if let entry { log.finish(entry, output: output) }
            operationError = nil
            succeeded = true
        } catch {
            log.fail(entry ?? log.start(repository: record.name, command: command, started: started), error: error)
            operationError = error
        }
        writesInFlight -= 1
        await refresh()
        return succeeded
    }

    // MARK: - Watching the folder

    /// Refreshes on changes made outside the app while this repository is
    /// on screen (plan D10), until the calling task is cancelled.
    func watchFileSystem() async {
        guard let gitDirectory = try? await repository.gitDirectory() else { return }
        let ignored = (try? await repository.ignoredDirectories()) ?? []
        watchFilter = WatchFilter(root: record.path, gitDirectory: gitDirectory.path, ignoredDirectories: ignored)
        // A linked work tree keeps its git directory elsewhere; watch that too.
        let inside = gitDirectory.path.hasPrefix(record.path + "/")
        for await batch in RepositoryWatcher.events(paths: inside ? [record.path] : [record.path, gitDirectory.path]) {
            if watchFilter?.isRelevant(batch) == true { scheduleWatchRefresh() }
        }
        watchRefresh?.cancel()
        watchRefresh = nil
        watchFilter = nil
    }

    /// 0.4 s after the first change, so an editor's save (temp file,
    /// rename) is read once, and at most once a second during a storm.
    private func scheduleWatchRefresh() {
        guard watchRefresh == nil else { return }
        let delay = max(.milliseconds(400), lastWatchRefresh + .seconds(1) - .now)
        watchRefresh = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            watchRefresh = nil
            // A write running now refreshes when it ends.
            guard writesInFlight == 0 else { return }
            lastWatchRefresh = .now
            await refresh()
            // A build may have just made a new ignored folder.
            if let ignored = try? await repository.ignoredDirectories() { watchFilter?.update(ignoredDirectories: ignored) }
        }
    }
}

import AppKit
import SourceDeckCore
import Observation

/// The repositories in the sidebar, in the user's order, kept in step with
/// the database, plus what the sidebar has selected.
@MainActor
@Observable
final class RepositoryList {
    enum Selection: Hashable {
        case dashboard
        case repository(String)
    }

    private(set) var models: [RepositoryModel] = []
    var selection: Selection? = .dashboard {
        didSet {
            if case .repository(let id) = selection {
                UserDefaults.standard.set(id, forKey: AppSettings.lastSelectedRepositoryKey)
            }
        }
    }
    private(set) var isFetchingAll = false
    /// Folder names that were added but aren't git repositories.
    var rejectedFolders: [String] = []
    var isScanSheetPresented = false
    var isCloneSheetPresented = false
    let log = OperationLog()

    @ObservationIgnored let store: RepositoryStore
    @ObservationIgnored let drafts: CommitDraftStore
    @ObservationIgnored let git: GitProcess
    @ObservationIgnored let signIn: RemoteSignIn
    @ObservationIgnored private var autoFetchTask: Task<Void, Never>?

    /// At most this many git processes at once (12
    /// repositories refresh in 87 ms).
    static let concurrency = 4

    init(database: AppDatabase, git: GitProcess) {
        store = RepositoryStore(dbQueue: database.dbQueue)
        drafts = CommitDraftStore(dbQueue: database.dbQueue)
        self.git = git
        signIn = RemoteSignIn(git: git, log: log)
        if let id = UserDefaults.standard.string(forKey: AppSettings.lastSelectedRepositoryKey) {
            selection = .repository(id)
        }
        Task { await observeRecords() }
        scheduleAutoFetch(minutes: AppSettings.autoFetchMinutes)
        signIn.onSignedIn = { [weak self] host in
            guard let self else { return }
            Task { await fetchWaiting(forAccountOn: host) }
        }
    }

    var selectedModel: RepositoryModel? {
        guard case .repository(let id) = selection else { return nil }
        return models.first { $0.id == id }
    }

    func model(id: String) -> RepositoryModel? {
        models.first { $0.id == id }
    }

    // MARK: - Keeping in step with the database

    private func observeRecords() async {
        do {
            for try await records in store.updates() {
                apply(records)
            }
        } catch {
            // The observation only ends with the database itself.
        }
    }

    /// Existing models are kept (with their state); new records get a model
    /// that refreshes itself at once.
    private func apply(_ records: [RepositoryRecord]) {
        var existing = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        models = records.map { record in
            if let model = existing.removeValue(forKey: record.id) {
                model.update(record)
                return model
            }
            let model = RepositoryModel(record: record, git: git, log: log, drafts: drafts, signIn: signIn)
            Task { await model.refresh() }
            return model
        }
        if case .repository(let id) = selection, !models.contains(where: { $0.id == id }) {
            selection = .dashboard
        }
    }

    // MARK: - Adding and arranging

    /// A folder anywhere inside a work tree adds the work tree. Adding one
    /// that is already listed selects it (`select`: the last one added).
    func add(_ urls: [URL], select: Bool = true) async {
        var lastID: String?
        var rejected: [String] = []
        for url in urls {
            do {
                let repository = try await GitRepository.open(url, git: git)
                lastID = try store.add(path: repository.root.path).id
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        rejectedFolders = rejected
        if select, let lastID { selection = .repository(lastID) }
    }

    func chooseFoldersToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
    }

    /// Clones into `destination`, logs it like a push, then lists and
    /// selects the new repository. Cancelling the task stops git, which
    /// removes the folder it made.
    func clone(_ url: String, into destination: URL) async throws {
        let entry = log.start(repository: destination.lastPathComponent, command: "git clone \(url) \(destination.path)")
        do {
            log.finish(entry, output: try await GitRepository.clone(url, into: destination, git: git))
        } catch {
            log.fail(entry, error: error)
            throw error
        }
        await add([destination])
    }

    func rename(_ model: RepositoryModel, to name: String) {
        try? store.rename(id: model.id, to: name)
    }

    /// Only the entry goes; the folder on disk is not touched.
    /// A square PNG, or nil for the initials.
    func setAvatar(_ model: RepositoryModel, to png: Data?) {
        try? store.setAvatar(id: model.id, to: png)
    }

    func remove(_ model: RepositoryModel) {
        try? store.remove(id: model.id)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        try? store.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Every repository at once

    func saveDrafts() {
        models.forEach { $0.saveDraft() }
    }

    func refreshAll() async {
        await forEachModel { await $0.refresh() }
    }

    /// Never opens the Sign In sheet: a repository that needs an account
    /// keeps its banner, with "Sign In…".
    func fetchAll() async {
        guard !isFetchingAll else { return }
        isFetchingAll = true
        defer { isFetchingAll = false }
        await forEachModel { await $0.run(.fetch, interactive: false) }
    }

    /// Once an account for `host` is saved, the other repositories that
    /// failed for want of it fetch again, so their banners go.
    func fetchWaiting(forAccountOn host: String) async {
        let waiting = models.filter { model in
            guard let url = (model.operationError as? GitCommandError)?.credentialURL else { return false }
            return RemoteSignIn.host(of: url) == host
        }
        // Usually one or two repositories: one after another is enough.
        for model in waiting { await model.run(.fetch, interactive: false) }
    }

    /// 0 turns it off. Restarted whenever Settings changes the interval.
    func scheduleAutoFetch(minutes: Int) {
        autoFetchTask?.cancel()
        guard minutes > 0 else { return }
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await self?.fetchAll()
            }
        }
    }

    private func forEachModel(_ body: @escaping @MainActor @Sendable (RepositoryModel) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = models.makeIterator()
            for _ in 0..<Self.concurrency {
                guard let model = pending.next() else { break }
                group.addTask { await body(model) }
            }
            while await group.next() != nil {
                if let model = pending.next() { group.addTask { await body(model) } }
            }
        }
    }
}

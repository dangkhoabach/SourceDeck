import DKBSourceControlCore
import Foundation
import Observation

/// One repository of the list: its last known state and the remote
/// operation running on it, if any.
@MainActor
@Observable
final class RepositoryModel: Identifiable {
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
    /// The last failed remote operation, until the next one succeeds.
    private(set) var operationError: Error?
    @ObservationIgnored private var remoteLoaded = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private let log: OperationLog

    /// The record's id, which never changes; readable from any isolation
    /// as `Identifiable` requires.
    nonisolated let id: String
    var folderExists: Bool { FileManager.default.fileExists(atPath: record.path) }

    init(record: RepositoryRecord, git: GitProcess, log: OperationLog) {
        self.record = record
        id = record.id
        repository = GitRepository(root: record.url, git: git)
        self.log = log
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

    func dismissOperationError() {
        operationError = nil
    }

    /// - Parameter setUpstream: for a push, the branch to publish when it
    ///   has no upstream yet.
    func run(_ operation: RemoteOperation, setUpstream: String? = nil) async {
        guard runningOperation == nil else { return }
        runningOperation = operation
        let entry = log.start(repository: record.name, command: operation.command)
        do {
            let output = switch operation {
            case .fetch: try await repository.fetch()
            case .pull: try await repository.pull(mode: AppSettings.pullMode)
            case .push: try await repository.push(setUpstream: setUpstream)
            }
            log.finish(entry, output: output)
            operationError = nil
        } catch {
            log.fail(entry, error: error)
            operationError = error
        }
        runningOperation = nil
        await refresh()
    }
}

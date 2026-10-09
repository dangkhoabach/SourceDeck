import DKBSourceControlCore
import Foundation
import Observation

/// Every fetch, pull, push, commit and discard, and every write that
/// failed, with git's own output (plan §7.3: the verbatim text, never just
/// "an error occurred"). Shown in the inspector.
@MainActor
@Observable
final class OperationLog {
    struct Entry: Identifiable {
        let id = UUID()
        let repository: String
        let command: String
        var started = Date()
        var finished: Date?
        var output = ""
        /// nil while running.
        var succeeded: Bool?
    }

    /// Newest first. Old entries go once there are this many; it is a log
    /// of this session, not history.
    private(set) var entries: [Entry] = []
    static let limit = 200

    /// - Parameter started: when the command began, for one logged only
    ///   once it has failed.
    func start(repository: String, command: String, started: Date = Date()) -> Entry.ID {
        entries.insert(Entry(repository: repository, command: command, started: started), at: 0)
        if entries.count > Self.limit { entries.removeLast() }
        return entries[0].id
    }

    func finish(_ id: Entry.ID, output: OperationOutput) {
        update(id, succeeded: true, output: [output.stderr, output.stdout])
    }

    func fail(_ id: Entry.ID, error: Error) {
        update(id, succeeded: false, output: [GitErrorText.output(of: error)])
    }

    func clear() {
        entries.removeAll { $0.succeeded != nil }
    }

    private func update(_ id: Entry.ID, succeeded: Bool, output: [String]) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].succeeded = succeeded
        entries[index].finished = Date()
        entries[index].output = output.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// One plain sentence above git's own message, picked by the kind of failure.
enum GitErrorText {
    static func hint(for error: Error) -> LocalizedStringResource {
        switch error {
        case let error as GitCommandError:
            switch error.kind {
            case .authenticationFailed:
                if error.needsSignIn {
                    "git needs an account for this remote. Sign in to continue."
                } else {
                    "git couldn't sign in to the remote. Check the credentials saved in Keychain or your SSH key."
                }
            case .networkUnreachable: "The remote's server can't be reached. Check the network connection, then try again."
            case .remoteNotFound: "The remote can't be reached: there is no remote named origin, or its address is wrong."
            case .repositoryNotFound: "There is no repository at this address, or your account can't see it. Check the URL and your access."
            case .hostKeyUnverified: "This Mac doesn't trust the server's SSH key yet. Run “ssh -T git@github.com” once in Terminal and answer yes, or use the HTTPS URL."
            case .noUpstream: "This branch has no upstream yet. Push it once to publish it."
            case .detachedHead: "HEAD isn't on a branch. Switch to a branch in Branches first."
            case .indexLocked: "Another git process is using this repository. Wait for it to finish, then try again."
            case .nonFastForward: "The remote has commits you don't have yet. Pull first, then push."
            case .remoteRejected: "The server refused the push, for example a protected branch."
            case .diverged: "Your branch and the remote both have new commits. Pull with rebase (Settings › Remote) or resolve it in Sourcetree."
            case .localChangesWouldBeOverwritten: "Your local changes would be overwritten. Commit or stash them first."
            case .conflict: "There are conflicts to resolve before you can continue."
            case .patchDoesNotApply: "The change no longer matches the file. Refresh and try again."
            case .branchNotFullyMerged: "This branch has commits that aren't merged anywhere else, so it was kept."
            case .notARepository: "This folder is not a git repository any more."
            case .other: "git reported an error."
            }
        case is TrashService.Failure: "A file couldn't be moved to the Trash, so the discard stopped there."
        case GitError.timedOut: "git didn't finish in time and was stopped."
        case GitError.launchFailed: "git couldn't be started."
        case is CancellationError: "Stopped before it finished."
        default: "Something went wrong."
        }
    }

    /// git's own text, or the error's description when git never ran.
    static func output(of error: Error) -> String {
        switch error {
        case let error as GitCommandError: error.output
        case GitError.launchFailed(let path, let reason): "\(path): \(reason)"
        case let error as TrashService.Failure: "\(error.path): \(error.underlying.localizedDescription)"
        case is CancellationError: ""
        default: error.localizedDescription
        }
    }
}

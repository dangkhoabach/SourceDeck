import Foundation

/// A git command that ran and failed. `output` is git's own text, shown to
/// the user verbatim (plan §7.3); `kind` only picks the one-line hint above it.
public struct GitCommandError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case authenticationFailed
        /// No network, or the remote's host can't be resolved or reached.
        case networkUnreachable
        /// No remote of that name, or its address leads nowhere.
        case remoteNotFound
        /// Clone: nothing at that address, or no access to it (GitHub
        /// answers "not found" for a private repository it won't show).
        case repositoryNotFound
        /// SSH refused a server whose key isn't in known_hosts yet: with no
        /// terminal, ssh can't ask whether to trust it.
        case hostKeyUnverified
        /// Pull on a branch that was never published.
        case noUpstream
        /// Pull or push with HEAD on no branch.
        case detachedHead
        case indexLocked
        /// Push refused: the remote has commits this branch doesn't.
        case nonFastForward
        /// Push refused by the server itself (protected branch, server hook).
        case remoteRejected
        /// `pull --ff-only` with local and remote commits on both sides.
        case diverged
        case localChangesWouldBeOverwritten
        case conflict
        case patchDoesNotApply
        case branchNotFullyMerged
        case notARepository
        case other
    }

    public let kind: Kind
    public let arguments: [String]
    public let exitCode: Int32
    /// stderr, then stdout when it has anything (merge prints CONFLICT there).
    public let output: String
    /// The HTTP(S) address git asked an account for, as git wrote it: no
    /// account saved yet, or the saved one was refused. nil for SSH.
    public let credentialURL: String?

    /// git stopped for an account the user can type in (plan: remote sign-in).
    public var needsSignIn: Bool { kind == .authenticationFailed && credentialURL != nil }

    init(arguments: [String], result: GitResult) {
        let stdout = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.arguments = arguments
        exitCode = result.exitCode
        output = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        kind = GitErrorClassifier.classify(output)
        credentialURL = kind == .authenticationFailed ? GitErrorClassifier.credentialURL(in: output) : nil
    }
}

/// Recognises git's failure messages (English: `LC_ALL` is fixed, D5). The
/// patterns come from real git 2.54 output; the order matters where one
/// message contains another's words.
enum GitErrorClassifier {
    private static let rules: [(GitCommandError.Kind, [String])] = [
        (.notARepository, ["not a git repository"]),
        (.networkUnreachable, ["Could not resolve host", "Couldn't connect to server", "Failed to connect to",
                               "Connection timed out", "Operation timed out", "Network is unreachable", "Connection refused"]),
        (.authenticationFailed, ["could not read Username", "could not read Password", "Authentication failed",
                                 "Permission denied (publickey", "terminal prompts disabled", "Invalid username or token"]),
        (.remoteNotFound, ["does not appear to be a git repository"]),
        (.repositoryNotFound, ["Repository not found", "' does not exist"]),
        (.hostKeyUnverified, ["Host key verification failed"]),
        (.noUpstream, ["There is no tracking information"]),
        (.detachedHead, ["You are not currently on a branch"]),
        (.indexLocked, ["index.lock': File exists"]),
        (.remoteRejected, ["[remote rejected]", "hook declined"]),
        (.nonFastForward, ["(fetch first)", "(non-fast-forward)", "Updates were rejected because"]),
        (.diverged, ["Not possible to fast-forward", "Diverging branches"]),
        (.localChangesWouldBeOverwritten, ["would be overwritten by"]),
        (.conflict, ["CONFLICT (", "Automatic merge failed", "could not apply", "Resolve all conflicts"]),
        (.patchDoesNotApply, ["patch does not apply", "patch failed", "corrupt patch"]),
        (.branchNotFullyMerged, ["is not fully merged"]),
    ]

    static func classify(_ output: String) -> GitCommandError.Kind {
        rules.first { _, patterns in patterns.contains { output.contains($0) } }?.0 ?? .other
    }

    /// From "could not read Username for '<url>'" (nothing saved),
    /// "could not read Password for '<url>'" (the URL names the user) and
    /// "Authentication failed for '<url>'" (the saved account was refused;
    /// git has already removed it). Taken from git's words rather than the
    /// remote's configured URL, so `insteadOf`, `pushurl` and a clone's URL
    /// are already applied.
    static func credentialURL(in output: String) -> String? {
        let pattern = #/(?:could not read (?:Username|Password) for|Authentication failed for) '([^']+)'/#
        guard let match = output.firstMatch(of: pattern) else { return nil }
        let url = String(match.1)
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

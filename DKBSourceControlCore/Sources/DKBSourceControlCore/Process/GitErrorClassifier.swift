import Foundation

/// A git command that ran and failed. `output` is git's own text, shown to
/// the user verbatim (plan §7.3); `kind` only picks the one-line hint above it.
public struct GitCommandError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case authenticationFailed
        /// No remote of that name, or its address leads nowhere.
        case remoteNotFound
        /// Pull on a branch that was never published.
        case noUpstream
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

    init(arguments: [String], result: GitResult) {
        let stdout = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.arguments = arguments
        exitCode = result.exitCode
        output = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        kind = GitErrorClassifier.classify(output)
    }
}

/// Recognises git's failure messages (English: `LC_ALL` is fixed, D5). The
/// patterns come from real git 2.54 output; the order matters where one
/// message contains another's words.
enum GitErrorClassifier {
    private static let rules: [(GitCommandError.Kind, [String])] = [
        (.notARepository, ["not a git repository"]),
        (.authenticationFailed, ["could not read Username", "could not read Password", "Authentication failed",
                                 "Permission denied (publickey", "terminal prompts disabled", "Invalid username or token"]),
        (.remoteNotFound, ["does not appear to be a git repository"]),
        (.noUpstream, ["There is no tracking information"]),
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
}

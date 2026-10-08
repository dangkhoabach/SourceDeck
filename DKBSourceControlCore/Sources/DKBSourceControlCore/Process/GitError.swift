import Foundation

/// Failures to *run* git. A git command that ran and exited non-zero is not
/// an error here: it comes back as a `GitResult`, because some commands use
/// exit code 1 for a normal answer (`diff --no-index` with differences).
public enum GitError: Error, Equatable, Sendable {
    case launchFailed(path: String, reason: String)
    case timedOut(Duration)
}

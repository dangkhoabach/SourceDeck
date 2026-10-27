import SourceDeckCore
import Foundation

/// Signing in to an HTTPS remote when git stops for an account.
/// The account goes to the user's own credential helper
/// through `git credential approve`, the way git saves one typed in
/// Terminal, and the command that failed runs again. The app keeps no copy.
///
/// Whoever shows the sheet (a repository, the Clone sheet, Settings) keeps
/// its own `Request`; this only prepares and completes them.
@MainActor
final class RemoteSignIn {
    struct Request: Identifiable {
        enum Reason: Equatable {
            /// Nothing saved for this remote yet.
            case missing
            /// The saved account was refused; git has removed it.
            case refused
            /// The account just typed was refused.
            case wrongPassword
            /// No credential helper would keep it, so signing in can't help.
            case noHelper
            /// The helper couldn't save it: git's own words.
            case failed(String)
        }

        let id = UUID()
        /// As git wrote it; the helper keeps the account by host.
        let url: String
        /// Where `git credential` runs: the repository, or a clone's parent folder.
        let directory: URL
        var username: String
        var reason: Reason
        /// Runs the failed command again, without asking again, and returns
        /// the error it failed with. nil from Settings: only the account is saved.
        let retry: (@MainActor () async -> Error?)?

        var host: String { RemoteSignIn.host(of: url) }
    }

    private let git: GitProcess
    private let log: OperationLog
    /// After a sign-in that worked, with its host: the list fetches the
    /// other repositories that failed for want of the same account.
    var onSignedIn: ((String) -> Void)?

    init(git: GitProcess, log: OperationLog) {
        self.git = git
        self.log = log
    }

    /// A request for `error` when git stopped for an account it can be
    /// given, otherwise nil (SSH, or not an account problem).
    func request(for error: Error, in directory: URL, retry: (@MainActor () async -> Error?)?) async -> Request? {
        guard let error = error as? GitCommandError, error.needsSignIn, let url = error.credentialURL else { return nil }
        return await request(url: url, in: directory, refused: error.output.contains("Authentication failed"), retry: retry)
    }

    /// For Settings › Accounts: a host's sign-in, with nothing to run again.
    func request(url: String, in directory: URL, refused: Bool = false,
                 retry: (@MainActor () async -> Error?)? = nil) async -> Request {
        // Asked once per request: without a helper, approve saves nothing.
        let hasHelper = (try? await git.hasCredentialHelper(for: url, in: directory)) ?? true
        return Request(url: url, directory: directory, username: URLComponents(string: url)?.user ?? "",
                       reason: hasHelper ? (refused ? .refused : .missing) : .noHelper, retry: retry)
    }

    /// Saves the account, then runs the command again.
    /// - Returns: nil when done, or the request to show again (wrong
    ///   password, or the helper failed).
    func submit(_ request: Request, username: String, password: String) async -> Request? {
        var request = request
        request.username = username
        let credential = GitCredential(url: request.url, username: username, password: password)
        let entry = log.start(repository: request.host, command: "git credential approve \(request.url) (\(username))")
        do {
            try await git.approve(credential, in: request.directory)
            log.finish(entry, output: OperationOutput())
        } catch {
            log.fail(entry, error: error)
            request.reason = .failed(GitErrorText.output(of: error))
            return request
        }
        if let retry = request.retry, let error = await retry() as? GitCommandError, error.needsSignIn {
            // git removes an account it saw refused; this covers helpers that don't.
            try? await git.reject(credential, in: request.directory)
            request.reason = .wrongPassword
            return request
        }
        onSignedIn?(request.host)
        return nil
    }

    /// Removes a host's saved account (Settings › Accounts).
    func signOut(url: String, username: String, in directory: URL) async throws {
        let entry = log.start(repository: Self.host(of: url), command: "git credential reject \(url) (\(username))")
        do {
            try await git.reject(GitCredential(url: url, username: username, password: ""), in: directory)
            log.finish(entry, output: OperationOutput())
        } catch {
            log.fail(entry, error: error)
            throw error
        }
    }

    /// An HTTP(S) host the listed repositories use, and who is signed in
    /// to it (Settings › Accounts).
    struct Account: Identifiable {
        /// "https://host[:port]": what the helper keeps the account by.
        let url: String
        /// A repository using it, where git reads the helper settings.
        let directory: URL
        var username: String?

        var id: String { url }
        var host: String { RemoteSignIn.host(of: url) }
    }

    /// The HTTP(S) hosts of the repositories' remotes, by name, with who is
    /// signed in to each, and whether any remote uses SSH instead. Never
    /// asks: `savedUsername` keeps prompts and windows off.
    func accounts(of repositories: [GitRepository]) async -> (accounts: [Account], usesSSH: Bool) {
        var byURL: [String: Account] = [:]
        var usesSSH = false
        for repository in repositories {
            for raw in (try? await repository.remoteURLs()) ?? [] {
                if let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
                   scheme == "https" || scheme == "http", let host = components.host {
                    let url = "\(scheme)://\(components.port.map { "\(host):\($0)" } ?? host)"
                    if byURL[url] == nil { byURL[url] = Account(url: url, directory: repository.root) }
                } else if raw.hasPrefix("ssh://") || (!raw.contains("://") && !raw.hasPrefix("/") && raw.contains(":")) {
                    // "git@github.com:owner/repo.git"; a local path has no account.
                    usesSSH = true
                }
            }
        }
        var accounts = byURL.values.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        for index in accounts.indices {
            accounts[index].username = try? await git.savedUsername(for: accounts[index].url, in: accounts[index].directory)
        }
        return (accounts, usesSSH)
    }

    /// "git.example.com:3000": what a helper keeps an account by, and what
    /// the sheet names. The user, path and scheme don't count.
    nonisolated static func host(of url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        return components.port.map { "\(host):\($0)" } ?? host
    }
}

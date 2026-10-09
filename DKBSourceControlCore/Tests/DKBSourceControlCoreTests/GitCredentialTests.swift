import Foundation
import Testing
@testable import DKBSourceControlCore

/// Signing in to an HTTP(S) remote through `git credential`, against the
/// `store` helper of a sandbox: never the Keychain (plan: remote sign-in).
@Suite struct GitCredentialTests {
    private static let username = "alice"
    private static let password = "s3cret-for-tests"

    @Test func lineBreaksAndNulAreRefusedBeforeGitRuns() async throws {
        let sandbox = try CredentialSandbox()
        for bad in ["a\nb", "a\rb", "a\0b"] {
            await #expect(throws: GitCredentialError.lineBreakInValue) {
                try await sandbox.git.approve(GitCredential(url: "https://example.test", username: bad, password: "p"), in: sandbox.root)
            }
            await #expect(throws: GitCredentialError.lineBreakInValue) {
                try await sandbox.git.approve(GitCredential(url: "https://example.test", username: "u", password: bad), in: sandbox.root)
            }
        }
        #expect(sandbox.storedLines().isEmpty)
    }

    @Test func approveSavesByHostAndRejectRemoves() async throws {
        let sandbox = try CredentialSandbox()
        let credential = GitCredential(url: "https://git.example.test:3000/team/repo.git", username: Self.username, password: Self.password)

        try await sandbox.git.approve(credential, in: sandbox.root)
        // Without credential.useHttpPath the path is dropped: one account per host.
        #expect(sandbox.storedLines() == ["https://alice:\(Self.password)@git.example.test%3a3000"])
        #expect(try await sandbox.git.savedUsername(for: "https://git.example.test:3000", in: sandbox.root) == Self.username)

        try await sandbox.git.reject(credential, in: sandbox.root)
        #expect(sandbox.storedLines().isEmpty)
        #expect(try await sandbox.git.savedUsername(for: "https://git.example.test:3000", in: sandbox.root) == nil)
    }

    @Test func aHelperCountsOnlyWhenTheLastValueForTheURLIsOne() async throws {
        let sandbox = try CredentialSandbox()
        let url = "https://git.example.test:3000/repo.git"
        #expect(try await sandbox.git.hasCredentialHelper(for: url, in: sandbox.root))

        try sandbox.setHelper(nil)
        #expect(try await !sandbox.git.hasCredentialHelper(for: url, in: sandbox.root))

        // An empty value clears the list: approve would save nothing.
        try sandbox.setHelper("store", thenReset: true)
        #expect(try await !sandbox.git.hasCredentialHelper(for: url, in: sandbox.root))
    }

    /// Clone, push, fetch and pull against a server that wants an account:
    /// what git says with none, with the right one and with a wrong one.
    @Test(.enabled(if: AuthHTTPServer.isAvailable, "needs /usr/bin/python3 for the test server"))
    func signingInLetsEveryRemoteCommandThrough() async throws {
        let sandbox = try CredentialSandbox()
        let served = sandbox.root.appendingPathComponent("served", isDirectory: true)
        let seed = sandbox.root.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try await sandbox.run(["init", "-q", "--bare", "repo.git"], in: served)
        try await sandbox.run(["init", "-q"], in: seed)
        try await sandbox.run(["commit", "-q", "--allow-empty", "-m", "one"], in: seed)
        try await sandbox.run(["push", "-q", served.appendingPathComponent("repo.git").path, "main"], in: seed)

        let server = try AuthHTTPServer(root: served, username: Self.username, password: Self.password)
        let remote = server.url("repo.git")
        let host = "http://127.0.0.1:\(server.port)"
        let right = GitCredential(url: remote, username: Self.username, password: Self.password)
        let clone = sandbox.root.appendingPathComponent("clone", isDirectory: true)

        // Nothing saved: git names the host it wanted an account for.
        let noAccount = try await #require(throws: GitCommandError.self) {
            try await GitRepository.clone(remote, into: clone, git: sandbox.git)
        }
        #expect(noAccount.needsSignIn)
        #expect(noAccount.credentialURL == host)
        #expect(!FileManager.default.fileExists(atPath: clone.path))

        try await sandbox.git.approve(right, in: sandbox.root)
        _ = try await GitRepository.clone(remote, into: clone, git: sandbox.git)
        let repository = GitRepository(root: clone, git: sandbox.git)

        // Push: refused without the account, through with it.
        try await sandbox.run(["commit", "-q", "--allow-empty", "-m", "two"], in: clone)
        try await sandbox.git.reject(right, in: sandbox.root)
        let pushError = try await #require(throws: GitCommandError.self) { try await repository.push() }
        #expect(pushError.needsSignIn && pushError.credentialURL == host)
        let pullError = try await #require(throws: GitCommandError.self) { try await repository.pull(mode: .fastForwardOnly) }
        #expect(pullError.needsSignIn && pullError.credentialURL == host)
        try await sandbox.git.approve(right, in: sandbox.root)
        _ = try await repository.push()
        let served2 = try await sandbox.git.run(["log", "--format=%s", "main"], in: served.appendingPathComponent("repo.git"))
        #expect(served2.stdoutText == "two\none\n")

        // A wrong saved password: git says so with the full URL and removes it.
        try await sandbox.git.reject(right, in: sandbox.root)
        try await sandbox.git.approve(GitCredential(url: remote, username: Self.username, password: "wrong"), in: sandbox.root)
        let refused = try await #require(throws: GitCommandError.self) { try await repository.fetch() }
        #expect(refused.needsSignIn)
        #expect(refused.credentialURL == remote + "/")
        #expect(sandbox.storedLines().isEmpty)

        // The password never shows up in what an error carries.
        for error in [noAccount, pushError, pullError, refused] {
            #expect(!error.arguments.joined(separator: " ").contains(Self.password))
            #expect(!error.output.contains(Self.password))
        }
    }

    /// Without a helper, approve succeeds and keeps nothing: the app must
    /// check first or it would ask again and again.
    @Test(.enabled(if: AuthHTTPServer.isAvailable, "needs /usr/bin/python3 for the test server"))
    func withoutAHelperApproveKeepsNothing() async throws {
        let sandbox = try CredentialSandbox()
        let served = sandbox.root.appendingPathComponent("served", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try await sandbox.run(["init", "-q", "--bare", "repo.git"], in: served)
        let server = try AuthHTTPServer(root: served, username: Self.username, password: Self.password)
        let remote = server.url("repo.git")
        try sandbox.setHelper(nil)

        #expect(try await !sandbox.git.hasCredentialHelper(for: remote, in: sandbox.root))
        try await sandbox.git.approve(GitCredential(url: remote, username: Self.username, password: Self.password), in: sandbox.root)
        let error = try await #require(throws: GitCommandError.self) {
            try await GitRepository.clone(remote, into: sandbox.root.appendingPathComponent("clone"), git: sandbox.git)
        }
        #expect(error.needsSignIn)
    }
}

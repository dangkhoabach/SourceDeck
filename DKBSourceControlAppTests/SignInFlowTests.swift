import DKBSourceControlCore
import Foundation
import Testing
@testable import DKB_Source_Control

/// Signing in when git stops for an account (plan: remote sign-in), against
/// a local server that asks for one. git runs with a throwaway config whose
/// helper is `store` in the temp folder: never the Keychain or ~/.gitconfig.
private let testUsername = "alice"
private let testPassword = "s3cret-for-tests"

@MainActor
@Suite(.enabled(if: AuthHTTPServer.isAvailable, "needs /usr/bin/python3 for the test server"))
struct SignInFlowTests {

    /// A served repository with one commit, and git set up to reach it.
    private final class Remote {
        let root: URL
        let git: GitProcess
        let server: AuthHTTPServer
        var url: String { server.url("repo.git") }
        var storeURL: URL { root.appendingPathComponent("credentials") }

        init() async throws {
            let temp = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
            root = temp.appendingPathComponent("dkbsc-signin-\(UUID().uuidString)", isDirectory: true)
            let served = root.appendingPathComponent("served", isDirectory: true)
            let seed = root.appendingPathComponent("seed", isDirectory: true)
            try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
            git = GitProcess(environment: GitEnvironment(home: root.path, extraVariables: [
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": root.appendingPathComponent("gitconfig").path,
            ]))
            try Self.writeConfig(in: root, helper: true)
            for (arguments, directory) in [(["init", "-q", "--bare", "repo.git"], served), (["init", "-q"], seed),
                                           (["commit", "-q", "--allow-empty", "-m", "one"], seed),
                                           (["push", "-q", served.appendingPathComponent("repo.git").path, "main"], seed)] {
                let result = try await git.run(arguments, in: directory)
                #expect(result.succeeded, "\(result.stderr)")
            }
            server = try AuthHTTPServer(root: served, username: testUsername, password: testPassword)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func setHelper(_ on: Bool) throws {
            try Self.writeConfig(in: root, helper: on)
        }

        /// The `store` helper keeps accounts in "credentials" next to it.
        private static func writeConfig(in root: URL, helper: Bool) throws {
            var config = "[user]\n\tname = Test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n"
            if helper { config += "[credential]\n\thelper = store --file=\(root.appendingPathComponent("credentials").path)\n" }
            try Data(config.utf8).write(to: root.appendingPathComponent("gitconfig"))
        }

        func storedLines() -> [String] {
            ((try? String(contentsOf: storeURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// A clone made with the account, which is then forgotten.
        func clone(_ name: String) async throws -> URL {
            let credential = GitCredential(url: url, username: testUsername, password: testPassword)
            let destination = root.appendingPathComponent(name, isDirectory: true)
            try await git.approve(credential, in: root)
            _ = try await GitRepository.clone(url, into: destination, git: git)
            try await git.reject(credential, in: root)
            return destination
        }
    }

    private func listing(_ folders: [URL], with remote: Remote) async throws -> RepositoryList {
        let list = RepositoryList(database: try AppDatabase.inMemory(), git: remote.git)
        await list.add(folders, select: false)
        for _ in 0..<100 where list.models.count != folders.count { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.models.count == folders.count)
        return list
    }

    @Test func aFetchThatNeedsAnAccountAsksAndRunsAgainOnceSignedIn() async throws {
        let remote = try await Remote()
        let list = try await listing([try await remote.clone("clone")], with: remote)
        let model = try #require(list.models.first)

        await model.run(.fetch)
        let request = try #require(model.pendingSignIn)
        #expect(request.reason == .missing)
        #expect(request.host == "127.0.0.1:\(remote.server.port)")

        // A wrong password: asked again, and nothing wrong is kept.
        let again = try #require(await list.signIn.submit(request, username: testUsername, password: "wrong"))
        #expect(again.reason == .wrongPassword)
        #expect(again.username == testUsername)
        #expect(remote.storedLines().isEmpty)

        #expect(await list.signIn.submit(again, username: testUsername, password: testPassword) == nil)
        #expect(model.operationError == nil)
        #expect(remote.storedLines().count == 1)
        #expect(list.log.entries.contains { $0.command.contains("git credential approve") && $0.succeeded == true })
        #expect(!list.log.entries.contains { $0.command.contains(testPassword) || $0.output.contains(testPassword) })
    }

    @Test func fetchAllNeverAsksAndOneSignInFetchesTheOthersOnTheSameHost() async throws {
        let remote = try await Remote()
        let list = try await listing([try await remote.clone("one"), try await remote.clone("two")], with: remote)

        await list.fetchAll()
        #expect(list.models.allSatisfy { $0.pendingSignIn == nil })
        #expect(list.models.allSatisfy { ($0.operationError as? GitCommandError)?.needsSignIn == true })

        // "Sign In…" on one banner.
        let first = list.models[0]
        await first.askToSignIn()
        let request = try #require(first.pendingSignIn)
        #expect(await list.signIn.submit(request, username: testUsername, password: testPassword) == nil)
        #expect(first.operationError == nil)
        for _ in 0..<150 where list.models[1].operationError != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.models[1].operationError == nil)
    }

    @Test func withoutACredentialHelperTheSheetSaysSoInsteadOfAsking() async throws {
        let remote = try await Remote()
        let list = try await listing([try await remote.clone("clone")], with: remote)
        try remote.setHelper(false)

        let model = try #require(list.models.first)
        await model.run(.fetch)
        #expect(model.pendingSignIn?.reason == .noHelper)
    }

    /// Settings › Accounts: hosts from every remote, who is signed in, Sign In and Sign Out.
    @Test func accountsListHostsWithTheSavedUserAndSignOutForgetsIt() async throws {
        let remote = try await Remote()
        let clone = try await remote.clone("clone")
        _ = try await remote.git.run(["remote", "add", "upstream", "git@github.com:o/r.git"], in: clone)
        let list = try await listing([clone], with: remote)
        let repositories = list.models.map(\.repository)

        var (accounts, usesSSH) = await list.signIn.accounts(of: repositories)
        #expect(accounts.map(\.url) == ["http://127.0.0.1:\(remote.server.port)"])
        #expect(accounts.first?.username == nil)
        #expect(usesSSH)

        let account = try #require(accounts.first)
        let request = await list.signIn.request(url: account.url, in: account.directory)
        #expect(await list.signIn.submit(request, username: testUsername, password: testPassword) == nil)
        (accounts, _) = await list.signIn.accounts(of: repositories)
        #expect(accounts.first?.username == testUsername)

        try await list.signIn.signOut(url: account.url, username: testUsername, in: account.directory)
        (accounts, _) = await list.signIn.accounts(of: repositories)
        #expect(accounts.first?.username == nil)
        #expect(remote.storedLines().isEmpty)
    }

    @Test func aCloneThatNeedsAnAccountRunsAgainOnceSignedIn() async throws {
        let remote = try await Remote()
        let selected = UserDefaults.standard.string(forKey: AppSettings.lastSelectedRepositoryKey)
        defer { UserDefaults.standard.set(selected, forKey: AppSettings.lastSelectedRepositoryKey) }
        let list = try await listing([], with: remote)
        let destination = remote.root.appendingPathComponent("cloned", isDirectory: true)

        let error = try await #require(throws: GitCommandError.self) { try await list.clone(remote.url, into: destination) }
        let request = try #require(await list.signIn.request(for: error, in: remote.root) {
            do {
                try await list.clone(remote.url, into: destination)
                return nil
            } catch {
                return error
            }
        })
        #expect(await list.signIn.submit(request, username: testUsername, password: testPassword) == nil)
        for _ in 0..<100 where list.models.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.models.first?.record.path == destination.path)
    }
}

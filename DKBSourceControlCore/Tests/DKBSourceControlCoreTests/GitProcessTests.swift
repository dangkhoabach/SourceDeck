import Foundation
import Testing
@testable import DKBSourceControlCore

@Suite struct GitProcessTests {
    private let git = GitProcess(environment: GitEnvironment())
    private let temp = URL(fileURLWithPath: NSTemporaryDirectory())

    @Test func versionOfTheInstalledGitIsSupported() async throws {
        let version = try #require(try await git.version())
        #expect(version.isSupported)
    }

    @Test func nonZeroExitComesBackAsAResultNotAnError() async throws {
        let dir = temp.appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await git.run(["rev-parse", "--git-dir"], in: dir, readOnly: true)
        #expect(result.exitCode == 128)
        #expect(result.stderr.contains("not a git repository"))
    }

    @Test func stdinReachesGit() async throws {
        let result = try await git.run(["hash-object", "--stdin"], in: temp, stdin: Data("hello\n".utf8), readOnly: true)
        #expect(result.succeeded)
        // `printf 'hello\n' | git hash-object --stdin`
        #expect(result.stdoutText == "ce013625030ba8dba906f756967f9e9ca394464a\n")
    }

    @Test func readOnlyCommandsSkipOptionalLocksAndNothingEverPrompts() {
        let env = GitEnvironment(path: "/usr/bin:/bin", home: "/Users/x", sshAuthSock: nil)
        let read = env.variables(readOnly: true)
        let write = env.variables(readOnly: false)
        #expect(read["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(write["GIT_OPTIONAL_LOCKS"] == nil)
        for vars in [read, write] {
            #expect(vars["GIT_TERMINAL_PROMPT"] == "0")
            #expect(vars["GIT_EDITOR"] == "true")
            #expect(vars["PATH"] == "/usr/bin:/bin")
            #expect(vars["SSH_AUTH_SOCK"] == nil)
        }
    }
}

@Suite struct ProcessRunnerTests {
    private func shell(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        return p
    }

    @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
        // 2 MB on stdout and on stderr, far past the 64 KB pipe buffer.
        let output = try await ProcessRunner.run(
            shell("head -c 2000000 /dev/zero | tr '\\0' a; head -c 2000000 /dev/zero | tr '\\0' b >&2"),
            stdin: nil, timeout: .seconds(20))
        #expect(output.exitCode == 0)
        #expect(output.stdout.count == 2_000_000)
        #expect(output.stderr.count == 2_000_000)
    }

    @Test func timeoutTerminatesTheProcess() async throws {
        let start = ContinuousClock.now
        await #expect(throws: GitError.timedOut(.milliseconds(300))) {
            try await ProcessRunner.run(shell("sleep 10"), stdin: nil, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let start = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(shell("sleep 10"), stdin: nil, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func stdinTheProcessNeverReadsDoesNotKillTheApp() async throws {
        // `true` exits at once; writing 1 MB into its closed pipe would raise
        // SIGPIPE without F_SETNOSIGPIPE.
        let output = try await ProcessRunner.run(shell("true"), stdin: Data(count: 1_000_000), timeout: .seconds(10))
        #expect(output.exitCode == 0)
    }

    @Test func missingExecutableIsALaunchFailure() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/nonexistent/git")
        await #expect {
            try await ProcessRunner.run(p, stdin: nil, timeout: .seconds(5))
        } throws: { error in
            if case GitError.launchFailed(path: "/nonexistent/git", reason: _) = error { return true }
            return false
        }
    }
}

@Suite struct GitEnvironmentTests {
    @Test func markedPathIsReadBetweenMarkersAndMustContainUsrBin() {
        let m = GitEnvironment.pathMarker
        #expect(GitEnvironment.parseMarkedPath("banner\n\(m)/a/bin:/usr/bin:/bin\(m)") == "/a/bin:/usr/bin:/bin")
        #expect(GitEnvironment.parseMarkedPath("\(m)/a/bin\(m)") == nil)
        #expect(GitEnvironment.parseMarkedPath("no markers at all") == nil)
    }

    @Test func loginShellPathResolvesOnThisMac() async {
        let env = await GitEnvironment.resolve()
        #expect(env.pathSource == .loginShell)
        #expect(env.path.split(separator: ":").contains("/usr/bin"))
    }

    @Test func brokenShellFallsBackToTheFixedPath() async {
        let env = await GitEnvironment.resolve(shell: "/nonexistent/shell")
        #expect(env.pathSource == .fallback)
        #expect(env.path == GitEnvironment.fallbackPath)
    }

    @Test func versionParsing() {
        #expect(GitVersion(parsing: "git version 2.54.0 (Apple Git-157)") == GitVersion(major: 2, minor: 54, patch: 0))
        #expect(GitVersion(parsing: "git version 2.39\n") == GitVersion(major: 2, minor: 39, patch: 0))
        #expect(GitVersion(parsing: "nope") == nil)
        #expect(GitVersion(major: 2, minor: 29, patch: 9).isSupported == false)
        #expect(GitVersion(major: 2, minor: 30, patch: 0).isSupported)
    }
}

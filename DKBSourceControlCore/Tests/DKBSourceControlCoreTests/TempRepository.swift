import Foundation
import Testing
@testable import DKBSourceControlCore

/// A throwaway repository in the temp folder, driven by the real git — no
/// mocks (plan §4 Test). Removed when the value goes away.
final class TempRepository: @unchecked Sendable {
    let url: URL
    let git = GitProcess(environment: GitEnvironment())
    let repository: GitRepository

    /// The real path: /var is a symlink to /private/var and git reports real
    /// paths. (`resolvingSymlinksInPath` won't do: it strips "/private" again.)
    static let tempRoot = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory(),
                              isDirectory: true)

    /// - Parameter bare: a bare repository, to act as a local "remote".
    init(bare: Bool = false) async throws {
        url = Self.tempRoot.appendingPathComponent("dkbsc-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        repository = GitRepository(root: url, git: git)
        try await run("init", "-q", "-b", "main", bare ? "--bare" : nil)
        if !bare { try await configureIdentity() }
    }

    /// A clone of `remote`, with its own identity.
    init(cloning remote: TempRepository) async throws {
        url = Self.tempRoot.appendingPathComponent("dkbsc-test-\(UUID().uuidString)", isDirectory: true)
        repository = GitRepository(root: url, git: git)
        let result = try await git.run(["clone", "-q", remote.url.path, url.path], in: Self.tempRoot)
        #expect(result.succeeded, "\(result.stderr)")
        try await configureIdentity()
    }

    private func configureIdentity() async throws {
        try await run("config", "user.name", "Test")
        try await run("config", "user.email", "test@example.com")
        try await run("config", "commit.gpgsign", "false")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ content: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: url.appendingPathComponent(path)), as: UTF8.self)
    }

    /// Runs git in the repository and expects it to succeed.
    @discardableResult
    func run(_ arguments: String?...) async throws -> String {
        let args = arguments.compactMap { $0 }
        let result = try await git.run(args, in: url)
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result.stdoutText
    }

    func commitAll(_ message: String) async throws {
        try await run("add", "-A")
        try await run("commit", "-q", "-m", message)
    }

    func stagedDiff() async throws -> String {
        try await run("diff", "--cached", "--no-color")
    }
}

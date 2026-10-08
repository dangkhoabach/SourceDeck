import DKBSourceControlCore
import Foundation
import Testing
@testable import DKB_Source_Control

@MainActor
@Suite struct RepositoryListTests {
    private let git = GitProcess(environment: GitEnvironment())

    private func makeFolder(repository: Bool) async throws -> URL {
        let root = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
        let url = root.appendingPathComponent("dkbsc-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src/app"), withIntermediateDirectories: true)
        if repository { _ = try await git.run(["init", "-q", "-b", "main"], in: url) }
        return url
    }

    /// The database observation delivers asynchronously.
    private func waitForModels(_ list: RepositoryList, count: Int) async throws {
        for _ in 0..<100 where list.models.count != count { try await Task.sleep(for: .milliseconds(20)) }
        #expect(list.models.count == count)
    }

    @Test func addingASubfolderAddsTheWorkTreeOnceAndRejectsPlainFolders() async throws {
        let repo = try await makeFolder(repository: true)
        let plain = try await makeFolder(repository: false)
        defer { [repo, plain].forEach { try? FileManager.default.removeItem(at: $0) } }
        let list = RepositoryList(database: try AppDatabase.inMemory(), git: git)

        await list.add([repo.appendingPathComponent("src/app"), plain], select: false)
        try await waitForModels(list, count: 1)
        #expect(list.models.first?.record.path == repo.path)
        #expect(list.rejectedFolders == [plain.lastPathComponent])

        await list.add([repo], select: false)
        try await waitForModels(list, count: 1)
    }

    @Test func newModelsRefreshThemselvesAndRemovalLeavesTheFolder() async throws {
        let repo = try await makeFolder(repository: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let list = RepositoryList(database: try AppDatabase.inMemory(), git: git)
        await list.add([repo], select: false)
        try await waitForModels(list, count: 1)
        let model = try #require(list.models.first)
        for _ in 0..<100 where model.status == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.status?.head.isUnborn == true)

        list.remove(model)
        try await waitForModels(list, count: 0)
        #expect(FileManager.default.fileExists(atPath: repo.path))
    }

    @Test func aMissingFolderIsReportedNotRun() async throws {
        let repo = try await makeFolder(repository: true)
        let list = RepositoryList(database: try AppDatabase.inMemory(), git: git)
        await list.add([repo], select: false)
        try await waitForModels(list, count: 1)
        try FileManager.default.removeItem(at: repo)
        let model = try #require(list.models.first)
        await model.refresh()
        // A refresh still running from the add runs once more, after it.
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.folderExists)
        #expect(model.status == nil)
        #expect(model.refreshError != nil)
    }
}

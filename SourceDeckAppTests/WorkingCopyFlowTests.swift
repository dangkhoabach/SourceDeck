import SourceDeckCore
import Foundation
import Testing
@testable import SourceDeck

/// Stage, discard, hunk and commit flows of the Working Copy, on a real
/// repository in the temp folder (no mocked git).
@MainActor
@Suite struct WorkingCopyFlowTests {
    private let git = GitProcess(environment: GitEnvironment())

    private func makeModel() async throws -> (RepositoryModel, URL, CommitDraftStore) {
        let root = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
        let url = root.appendingPathComponent("dkbsc-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
                          ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(arguments, in: url)
        }
        let database = try AppDatabase.inMemory()
        let record = try RepositoryStore(dbQueue: database.dbQueue).add(path: url.path)
        let drafts = CommitDraftStore(dbQueue: database.dbQueue)
        return (RepositoryModel(record: record, git: git, log: OperationLog(), drafts: drafts), url, drafts)
    }

    private func write(_ text: String, to path: String, in url: URL) throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(path))
    }

    private func commitAll(_ url: URL) async throws {
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["commit", "-q", "-m", "init"], in: url)
    }

    @Test func discardSendsNewFilesToTheTrashAndRestoresTheRest() async throws {
        let (model, url, _) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("v1\n", to: "tracked.txt", in: url)
        try write("keep\n", to: "dkbsc-test-old.txt", in: url)
        try await commitAll(url)
        try write("v2\n", to: "tracked.txt", in: url)
        try write("new\n", to: "dkbsc-test-added-\(UUID().uuidString).txt", in: url)
        _ = try await git.run(["add", "-A"], in: url)
        _ = try await git.run(["mv", "dkbsc-test-old.txt", "dkbsc-test-renamed.txt"], in: url)
        try write("edited after the rename\n", to: "dkbsc-test-renamed.txt", in: url)
        await model.refresh()

        let workingCopy = model.workingCopy
        workingCopy.requestDiscard(Set(workingCopy.entries(.staged).map { .init(area: .staged, path: $0.path) }))
        let request = try #require(workingCopy.discardRequest)
        #expect(request.includingStaged && request.entries.count == 3)
        await workingCopy.discard(request)

        #expect(model.operationError == nil)
        #expect(model.status?.isClean == true)
        #expect(try String(contentsOf: url.appendingPathComponent("tracked.txt"), encoding: .utf8) == "v1\n")
        #expect(try String(contentsOf: url.appendingPathComponent("dkbsc-test-old.txt"), encoding: .utf8) == "keep\n")
        // The renamed file and the added one were moved, not deleted by git.
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("dkbsc-test-renamed.txt").path))
    }

    @Test func stagingOneHunkStagesOnlyThatHunk() async throws {
        let (model, url, _) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try write((1...30).map { "line \($0)\n" }.joined(), to: "n.txt", in: url)
        try await commitAll(url)
        try write((1...30).map { $0 == 2 ? "first\n" : $0 == 28 ? "second\n" : "line \($0)\n" }.joined(), to: "n.txt", in: url)
        await model.refresh()

        let workingCopy = model.workingCopy
        workingCopy.selection = [.init(area: .unstaged, path: "n.txt")]
        await workingCopy.loadDiff()
        guard case .file(let file, .unstaged, false) = workingCopy.diff else { Issue.record("no diff"); return }
        #expect(file.hunks.count == 2)
        await workingCopy.apply(hunk: 1, of: file, mode: .stage)

        let staged = try await git.run(["diff", "--cached", "-U0"], in: url).stdoutText
        #expect(staged.contains("+second") && !staged.contains("+first"))
        #expect(model.status?.entries.first?.hasStagedChange == true && model.status?.entries.first?.hasUnstagedChange == true)
    }

    @Test func aStagedSecretStopsTheCommitUntilItIsUnstaged() async throws {
        let (model, url, drafts) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("deploy"), withIntermediateDirectories: true)
        try write("KEY=x\n", to: "deploy/.env", in: url)
        try write("app\n", to: "app.txt", in: url)
        _ = try await git.run(["add", "-A"], in: url)
        await model.refresh()

        let composer = model.composer
        composer.draft = CommitDraft(keyword: .initial, lines: [.init(text: "Start the project"), .init(isSub: true, text: "App file")])
        #expect(composer.blockers.isEmpty)
        await composer.commit(push: false)
        #expect(composer.findings.map(\.path) == ["deploy/.env"])
        #expect(try await model.repository.log().isEmpty)

        await composer.unstageFindings()
        #expect(model.status?.entries.first { $0.path == "deploy/.env" }?.isUntracked == true)
        await composer.commit(push: false)
        #expect(composer.findings.isEmpty)

        // Byte for byte what git-rule asks, and the draft starts over.
        let stored = try await git.run(["log", "-1", "--format=%B"], in: url).stdoutText
        #expect(stored == "+ Initial +\n - Start the project\n  + App file\n\n")
        #expect(composer.draft.isEmpty)
        composer.saveNow()
        #expect(try drafts.draft(repositoryID: model.id)?.isEmpty == true)
        // A local commit can be amended until it is pushed.
        await composer.checkAmend()
        #expect(composer.canAmend)
    }

    /// An edit shows within a second;
    /// a build writing into an ignored folder refreshes nothing.
    @Test func theWatcherSeesEditsButNotIgnoredBuilds() async throws {
        let (model, url, _) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("build/\n", to: ".gitignore", in: url)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("build/out"), withIntermediateDirectories: true)
        try await commitAll(url)
        await model.refresh()
        let watching = Task { await model.watchFileSystem() }
        defer { watching.cancel() }
        try await Task.sleep(for: .milliseconds(500))

        let before = model.refreshCount
        for index in 0..<40 {
            try write("object \(index)", to: "build/out/\(index).o", in: url)
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(model.refreshCount == before)

        let edited = ContinuousClock.now
        try write("edited\n", to: "a.txt", in: url)
        while model.refreshCount == before, ContinuousClock.now - edited < .seconds(3) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ContinuousClock.now - edited < .seconds(1))
        #expect(model.status?.entries.map(\.path) == ["a.txt"])
    }

    /// A repository straight from `git init`: no HEAD to diff, unstage or
    /// amend against until the first commit.
    @Test func theFirstCommitOfANewRepository() async throws {
        let (model, url, _) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("hello\n", to: "README.md", in: url)
        await model.refresh()
        #expect(model.status?.head.isUnborn == true)
        await model.composer.checkAmend()
        #expect(!model.composer.canAmend)
        await model.history.reload()
        #expect(model.history.commits.isEmpty && model.history.loadError == nil)

        await model.workingCopy.stage(model.workingCopy.entries(.unstaged))
        model.composer.draft = CommitDraft(keyword: .initial, lines: [.init(text: "Start")])
        await model.composer.commit(push: false)
        #expect(model.operationError == nil)
        #expect(model.status?.head.isUnborn == false && model.status?.isClean == true)
        await model.history.reload()
        #expect(model.history.commits.map(\.message) == ["+ Initial +\n - Start"])
    }

    @Test func trashServiceMovesFilesAndSkipsMissingOnes() throws {
        let root = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
        let name = "dkbsc-test-trash-\(UUID().uuidString).txt"
        try Data("x".utf8).write(to: root.appendingPathComponent(name))
        try TrashService.moveToTrash([name, "dkbsc-test-missing.txt"], in: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    @Test func externalAppsAreInstalledCandidatesOnly() {
        let installed = ExternalApp.installed
        #expect(Set(installed.map(\.bundleID)).isSubset(of: ExternalApp.candidates))
        #expect(Set(installed.map(\.id)).count == installed.count)
        // Terminal ships with macOS.
        #expect(installed.contains { $0.bundleID == "com.apple.Terminal" })
        #expect(installed.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) && !$0.name.hasSuffix(".app") })
    }

    @Test func theDraftOutlivesTheComposer() async throws {
        let (model, url, drafts) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        model.composer.draft.lines[0].text = "Half written"
        model.saveDraft()
        #expect(try drafts.draft(repositoryID: model.id)?.lines.first?.text == "Half written")
        #expect(CommitComposer(model: model).draft.lines.first?.text == "Half written")
    }

    @Test func commitWaitsForAMessageAndStagedChanges() async throws {
        let (model, url, _) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try write("a\n", to: "a.txt", in: url)
        await model.refresh()
        let composer = model.composer
        #expect(composer.blockers == [.nothingStaged, .emptyMessage])
        composer.draft.rawText = "fix stuff"
        #expect(composer.blockers.contains(.message(.invalidHeader)))
        composer.isRaw = false
        #expect(composer.outlineSwitchFailed && composer.isRaw)
    }
}

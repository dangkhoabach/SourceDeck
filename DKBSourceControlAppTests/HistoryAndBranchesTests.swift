import DKBSourceControlCore
import Foundation
import Testing
@testable import DKB_Source_Control

/// History paging, branch switching and line staging through the app's
/// models, on real repositories in the temp folder.
@MainActor
@Suite struct HistoryAndBranchesTests {
    private let git = GitProcess(environment: GitEnvironment())

    private func makeModel() async throws -> (RepositoryModel, URL) {
        let root = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
        let url = root.appendingPathComponent("dkbsc-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.com"],
                          ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(arguments, in: url)
        }
        let database = try AppDatabase.inMemory()
        let record = try RepositoryStore(dbQueue: database.dbQueue).add(path: url.path)
        let model = RepositoryModel(record: record, git: git, log: OperationLog(), drafts: CommitDraftStore(dbQueue: database.dbQueue))
        return (model, url)
    }

    /// Setup steps that are shorter as a shell line than as git calls.
    private func sh(_ script: String, in url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = url
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(script)")
    }

    @Test func historyPagesSearchesAndReachesTheEnd() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("for i in $(seq 1 205); do git commit -q --allow-empty -m \"commit $i\"; done", in: url)
        let history = model.history

        await history.reload()
        #expect(history.commits.count == 200 && !history.reachedEnd)
        #expect(history.commits.first?.message == "commit 205")
        await history.loadMore()
        #expect(history.commits.count == 205 && history.reachedEnd)
        #expect(history.commits.last?.message == "commit 1")

        // Reading again after a new commit keeps as many as were shown.
        try await sh("git commit -q --allow-empty -m 'commit 206'", in: url)
        await history.reload()
        #expect(history.commits.count == 205 && history.commits.first?.message == "commit 206" && !history.reachedEnd)

        history.search = "COMMIT 20"
        await history.reload()
        #expect(history.commits.map(\.message) == ["commit 206", "commit 205", "commit 204", "commit 203", "commit 202",
                                                    "commit 201", "commit 200", "commit 20"])
    }

    @Test func switchingWithChangesAsksThenStashesFirst() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo a > a.txt && git add a.txt && git commit -qm init && git branch topic && echo changed > a.txt", in: url)
        await model.refresh()
        let branches = model.branches
        await branches.load()
        let topic = try #require(branches.local.first { $0.name == "topic" })

        await branches.requestSwitch(to: topic)
        #expect(branches.pendingSwitch == topic)
        #expect(model.status?.head.branch == "main")

        await branches.switchTo(topic, stashingFirst: true)
        await branches.load()
        #expect(model.status?.head.branch == "topic" && model.status?.isClean == true)
        #expect(branches.stashes.count == 1 && branches.stashes[0].message.contains("topic"))

        await branches.pop(branches.stashes[0])
        #expect(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8) == "changed\n")
    }

    /// Double-clicking "origin/feature/x" checks out a local "feature/x"
    /// that tracks it (git's own guess).
    @Test func aRemoteBranchChecksOutAsATrackingLocalBranch() async throws {
        let (model, url) = try await makeModel()
        let remote = url.appendingPathExtension("remote")
        defer { [url, remote].forEach { try? FileManager.default.removeItem(at: $0) } }
        try await sh("git init -q --bare -b main '\(remote.path)' && git remote add origin '\(remote.path)' && echo a > a.txt "
                     + "&& git add a.txt && git commit -qm init && git push -q origin main feature/x 2>/dev/null; "
                     + "git push -q origin main:refs/heads/feature/x && git fetch -q origin", in: url)
        await model.refresh()
        let branches = model.branches
        await branches.load()
        let feature = try #require(branches.remote.first { $0.name == "origin/feature/x" })

        await branches.requestSwitch(to: feature)
        await branches.load()
        #expect(model.status?.head.branch == "feature/x" && model.status?.head.upstream == "origin/feature/x")
        #expect(branches.local.map(\.name).sorted() == ["feature/x", "main"])
    }

    @Test func pickedLinesAreStagedAlone() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("seq 1 20 > n.txt && git add n.txt && git commit -qm init && sed -i '' -e 's/^5$/FIVE/' -e 's/^6$/SIX/' n.txt", in: url)
        await model.refresh()
        let workingCopy = model.workingCopy
        workingCopy.selection = [.init(area: .unstaged, path: "n.txt")]
        await workingCopy.loadDiff()
        guard case .file(let file, .unstaged, false) = workingCopy.diff else { Issue.record("no diff"); return }
        let lines = file.hunks[0].lines
        workingCopy.toggleLine(try #require(lines.firstIndex { $0.text == "6" }), hunk: 0)
        workingCopy.toggleLine(try #require(lines.firstIndex { $0.text == "SIX" }), hunk: 0)
        await workingCopy.apply(lines: workingCopy.selectedLines[0] ?? [], hunk: 0, of: file, mode: .stage)
        await workingCopy.loadDiff()

        let staged = try await git.run(["diff", "--cached", "-U0"], in: url).stdoutText
        #expect(staged.contains("-6\n+SIX") && !staged.contains("FIVE"))
        // The diff changed, so the picked lines are gone.
        #expect(workingCopy.selectedLines.isEmpty)
    }
}

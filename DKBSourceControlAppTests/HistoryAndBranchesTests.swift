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

    /// docs/history-actions-plan.md §3.1.
    @Test func revertStagesTheOppositeAndFillsTheComposerInWorkingCopy() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo one > a.txt && git add a.txt && git commit -qm one && echo two >> a.txt && git commit -qam two", in: url)
        await model.refresh()
        let history = model.history
        await history.reload()
        let two = try #require(history.commits.first)
        model.tab = .history

        await history.revert(two)
        #expect(model.tab == .workingCopy)
        #expect(model.status?.state == .reverting && model.status?.stagedCount == 1)
        #expect(model.composer.draft.message == "+ Update +\n - Revert \(two.shortOID): two")
        #expect(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        // The draft is saved half a second late, by then without its model.
        model.saveDraft()
    }

    /// docs/history-actions-plan.md §3.2: nothing uncommitted is lost.
    @Test func resetHardStashesEveryChangeFirst() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo one > a.txt && git add a.txt && git commit -qm one && echo two >> a.txt && git commit -qam two "
                     + "&& echo mine >> a.txt && echo new > new.txt", in: url)
        await model.refresh()
        let history = model.history
        await history.reload()
        let one = try #require(history.commits.last)

        await history.reset(to: one, mode: .hard)
        #expect(model.status?.head.oid == one.oid && model.status?.isClean == true)
        let stashes = try await model.repository.stashes()
        #expect(stashes.count == 1 && stashes[0].message.contains("Before resetting to \(one.shortOID)"))
        let stashed = try await git.run(["stash", "show", "--include-untracked", "--name-only", stashes[0].ref], in: url).stdoutText
        #expect(stashed == "a.txt\nnew.txt\n")
    }

    /// docs/history-actions-plan.md §3.3: the file is selected by its name
    /// at each commit, before a rename too.
    @Test func fileHistoryListsTheFilesCommitsAndSelectsItByItsNameThen() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo one > a.txt && git add a.txt && git commit -qm 'add a' && echo x > other.txt && git add other.txt "
                     + "&& git commit -qm other && git mv a.txt b.txt && git commit -qm rename", in: url)
        await model.refresh()
        let history = model.history

        history.showHistory(of: "b.txt")
        #expect(model.tab == .history)
        await history.reload()
        #expect(history.commits.map(\.message) == ["rename", "add a"])
        history.selection = history.commits.last?.oid
        await history.loadFiles()
        #expect(history.selectedFile == "a.txt")

        history.showAllHistory()
        await history.reload()
        #expect(history.commits.map(\.message) == ["rename", "other", "add a"])
    }

    /// docs/history-actions-plan.md §3.4: another branch's history, and a
    /// commit of it picked into the current one.
    @Test func anotherBranchsCommitIsCherryPickedIntoTheCurrentOne() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo a > a.txt && git add a.txt && git commit -qm one && git switch -qc feature && echo f > f.txt "
                     + "&& git add f.txt && git commit -qm 'feature f' && git switch -q main", in: url)
        await model.refresh()
        let history = model.history
        history.revision = "feature"
        await history.reload()
        #expect(history.commits.map(\.message) == ["feature f", "one"])

        await history.cherryPick(history.commits[0])
        #expect(model.status?.head.branch == "main" && model.lastCommit?.message == "feature f")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("f.txt").path))
    }

    /// Checking out a commit with changes asks first, then stashes them.
    @Test func checkingOutACommitStashesFirstAndABranchStartsThere() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo 1 > a.txt && git add a.txt && git commit -qm one && echo 2 > a.txt && git commit -qam two && echo 3 > a.txt", in: url)
        await model.refresh()
        let history = model.history
        await history.reload()
        let one = try #require(history.commits.last)

        await history.requestCheckout(one)
        #expect(history.pendingCheckout == one && model.status?.head.oid != one.oid)
        await history.checkout(one, stashingFirst: true)
        #expect(model.status?.head.isDetached == true && model.status?.head.oid == one.oid && model.status?.isClean == true)
        #expect(try await model.repository.stashes().first?.message.contains("Before checking out \(one.shortOID)") == true)

        #expect(await model.branches.create("fix", at: one))
        #expect(model.status?.head.branch == "fix" && model.status?.head.oid == one.oid)
    }

    /// docs/history-actions-plan.md §3.5: a version put back in the working
    /// copy, and a line's commit from Blame selected in the file's history.
    @Test func anOlderVersionIsRestoredAndBlameShowsALinesCommit() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo old > a.txt && git add a.txt && git commit -qm first && echo x > b.txt && git add b.txt "
                     + "&& git commit -qm other && echo new > a.txt && git commit -qam second", in: url)
        await model.refresh()
        let history = model.history
        await history.reload()
        let first = try #require(history.commits.last)
        model.tab = .history

        history.selection = first.oid
        await history.loadFiles()
        await history.restore(try #require(history.files.first), from: first)
        #expect(model.tab == .workingCopy && model.status?.unstagedCount == 1)
        #expect(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8) == "old\n")

        let line = try #require(try await model.repository.blame(path: "a.txt", at: first.oid).first)
        history.showCommit(line.oid, inHistoryOf: "a.txt")
        await history.reload()
        #expect(model.tab == .history && history.commits.map(\.message) == ["second", "first"])
        #expect(history.selection == first.oid)
    }

    /// docs/history-actions-plan.md §3.6: a merge that can't fast-forward
    /// waits for the composer; rename and tags.
    @Test func aMergeWaitsForTheComposerAndBranchesAreRenamedAndTagged() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo a > a.txt && git add a.txt && git commit -qm one && git switch -qc feature && echo f > f.txt "
                     + "&& git add f.txt && git commit -qm feature && git switch -q main && echo b > b.txt && git add b.txt "
                     + "&& git commit -qm main", in: url)
        await model.refresh()
        let branches = model.branches
        await branches.load()
        let feature = try #require(branches.local.first { $0.name == "feature" })

        await branches.merge(feature)
        #expect(model.tab == .workingCopy && model.status?.state == .merging)
        #expect(model.composer.draft.message == "+ Update +\n - Merge feature into main")
        await model.composer.commit(push: false)
        #expect(model.status?.state == .normal && model.lastCommit?.isMerge == true)

        await branches.rename(feature, to: "done")
        let head = try #require(model.lastCommit)
        await branches.createTag("v1", message: "", at: head)
        await branches.load()
        #expect(branches.local.map(\.name).sorted() == ["done", "main"] && branches.tags.map(\.name) == ["v1"])
        await branches.deleteTag(branches.tags[0])
        await branches.load()
        #expect(branches.tags.isEmpty)
        model.saveDraft()
    }

    /// docs/history-actions-plan.md §3.7: Apply brings the changes back and
    /// keeps the stash.
    @Test func applyKeepsTheStash() async throws {
        let (model, url) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: url) }
        try await sh("echo a > a.txt && git add a.txt && git commit -qm one && echo b > a.txt", in: url)
        await model.refresh()
        let branches = model.branches
        await branches.stash(message: "work")
        await branches.load()
        #expect(model.status?.isClean == true && branches.stashes.count == 1)

        await branches.apply(branches.stashes[0])
        await branches.load()
        #expect(model.status?.unstagedCount == 1 && branches.stashes.count == 1)
    }
}

import Foundation
import Testing
@testable import DKBSourceControlCore

/// Revert, reset and a file's history (docs/history-actions-plan.md,
/// phase 1), on real repositories in the temp folder.
@Suite struct HistoryActionsTests {
    @Test func fileHistoryFollowsARenameWithTheNameAtEachCommitAndPages() async throws {
        let repo = try await TempRepository()
        #expect(try await repo.repository.fileHistory(path: "b.txt").isEmpty)
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("add a")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("change a")
        try await repo.run("mv", "a.txt", "b.txt")
        try await repo.commitAll("rename")
        try repo.write("other.txt", "x\n")
        try await repo.commitAll("other file")
        try repo.write("b.txt", "one\ntwo\nthree\n")
        try await repo.commitAll("change b")

        let revisions = try await repo.repository.fileHistory(path: "b.txt")
        #expect(revisions.map(\.commit.message) == ["change b", "rename", "change a", "add a"])
        #expect(revisions.map(\.file?.path) == ["b.txt", "b.txt", "a.txt", "a.txt"])
        #expect(revisions.map(\.file?.change) == [.modified, .renamed, .modified, .added])
        #expect(revisions[1].file?.originalPath == "a.txt")

        let page = try await repo.repository.fileHistory(path: "b.txt", limit: 2, skip: 2)
        #expect(page.map(\.commit.message) == ["change a", "add a"])
    }

    @Test func revertStagesTheOppositeAndTheComposersCommitEndsIt() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("one")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("two")
        let two = try #require(try await repo.repository.log(limit: 1).first)

        _ = try await repo.repository.revert(two)
        var status = try await repo.repository.status()
        #expect(status.state == .reverting)
        #expect(status.entries.map(\.path) == ["a.txt"] && status.stagedCount == 1 && status.unstagedCount == 0)
        #expect(try repo.read("a.txt") == "one\n")

        _ = try await repo.repository.commit("+ Update +\n - Revert two\n")
        status = try await repo.repository.status()
        #expect(status.state == .normal && status.isClean)
        #expect(try await repo.repository.log(limit: 1).first?.message == "+ Update +\n - Revert two")
    }

    @Test func revertOfAMergeTakesBackWhatItBroughtIn() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("one")
        try await repo.run("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("feature")
        try await repo.run("switch", "-q", "main")
        try await repo.run("merge", "-q", "--no-ff", "-m", "merge", "feature")
        let merge = try #require(try await repo.repository.log(limit: 1).first)
        #expect(merge.isMerge)

        _ = try await repo.repository.revert(merge)
        let status = try await repo.repository.status()
        #expect(status.entries.map(\.path) == ["f.txt"] && status.entries.first?.index == .deleted)
    }

    @Test func resetSoftKeepsStagedMixedUnstagedAndHardNothing() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("one")
        let one = try #require(try await repo.repository.log(limit: 1).first)
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("two")
        let two = try #require(try await repo.repository.log(limit: 1).first)

        _ = try await repo.repository.reset(to: one.oid, mode: .soft)
        var status = try await repo.repository.status()
        #expect(status.head.oid == one.oid && status.stagedCount == 1 && status.unstagedCount == 0)

        _ = try await repo.repository.reset(to: two.oid, mode: .soft)
        _ = try await repo.repository.reset(to: one.oid, mode: .mixed)
        status = try await repo.repository.status()
        #expect(status.head.oid == one.oid && status.stagedCount == 0 && status.unstagedCount == 1)

        _ = try await repo.repository.reset(to: one.oid, mode: .hard)
        status = try await repo.repository.status()
        #expect(status.isClean)
        #expect(try repo.read("a.txt") == "one\n")
    }

    @Test func commitsAfterCountsThoseAlreadyPushed() async throws {
        let remote = try await TempRepository(bare: true)
        let repo = try await TempRepository(cloning: remote)
        try repo.write("a.txt", "1\n")
        try await repo.commitAll("one")
        let one = try #require(try await repo.repository.log(limit: 1).first)
        for n in 2...3 {
            try repo.write("a.txt", "\(n)\n")
            try await repo.commitAll("commit \(n)")
        }
        try await repo.run("push", "-q", "origin", "main")
        try repo.write("a.txt", "4\n")
        try await repo.commitAll("not pushed")

        let after = try await repo.repository.commitsAfter(one.oid)
        #expect(after.total == 3 && after.notOnRemote == 1)
        await #expect(throws: GitRepositoryError.self) { try await repo.repository.commitsAfter("--all") }
    }

    // MARK: - Phase 2: commit menu

    @Test func branchAndTagAtACommitAndCheckoutDetached() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "1\n")
        try await repo.commitAll("one")
        let one = try #require(try await repo.repository.log(limit: 1).first)
        try repo.write("a.txt", "2\n")
        try await repo.commitAll("two")

        _ = try await repo.repository.createTag("v1", at: one.oid)
        _ = try await repo.repository.createTag("v1-notes", at: one.oid, message: "First release\n")
        #expect(try await repo.run("rev-parse", "v1^{commit}", "v1-notes^{commit}") == "\(one.oid)\n\(one.oid)\n")
        #expect(try await repo.run("cat-file", "-t", "v1-notes") == "tag\n")

        _ = try await repo.repository.checkout(one.oid)
        var head = try await repo.repository.status().head
        #expect(head.isDetached && head.oid == one.oid)

        _ = try await repo.repository.createBranch("fix", at: one.oid)
        head = try await repo.repository.status().head
        #expect(head.branch == "fix" && head.oid == one.oid)
        await #expect(throws: GitRepositoryError.self) { try await repo.repository.createTag("x", at: "--all") }
    }

    @Test func cherryPickCommitsWithTheMessageAndAConflictStopsInProgress() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("one")
        try await repo.run("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("+ Create +\n - f")
        try repo.write("a.txt", "feature\n")
        try await repo.commitAll("feature a")
        let feature = try await repo.repository.log(revision: "feature", limit: 2)
        try await repo.run("switch", "-q", "main")
        try repo.write("a.txt", "main\n")
        try await repo.commitAll("main a")

        _ = try await repo.repository.cherryPick(feature[1])
        #expect(try await repo.repository.log(limit: 1).first?.message == "+ Create +\n - f")
        #expect(try repo.read("f.txt") == "f\n")

        await #expect(throws: GitCommandError.self) { try await repo.repository.cherryPick(feature[0]) }
        let status = try await repo.repository.status()
        #expect(status.state == .cherryPicking && status.hasConflicts)
        _ = try await repo.repository.abortInProgress()
        #expect(try await repo.repository.status().isClean)
    }

    // MARK: - Phase 3: blame and older versions

    @Test func blameNamesTheCommitOfEachLineAndTheUncommittedOnes() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.commitAll("first")
        let first = try #require(try await repo.repository.log(limit: 1).first)
        try repo.write("a.txt", "one\nTWO\n\tthree\n")
        try await repo.commitAll("second")
        let second = try #require(try await repo.repository.log(limit: 1).first)
        try repo.write("a.txt", "one\nTWO\n\tthree\nfour\n")

        let lines = try await repo.repository.blame(path: "a.txt")
        #expect(lines.map(\.text) == ["one", "TWO", "\tthree", "four"])
        #expect(lines.map(\.number) == [1, 2, 3, 4])
        #expect(lines.map(\.oid).prefix(3) == [first.oid, second.oid, second.oid])
        #expect(lines.map(\.summary).prefix(3) == ["first", "second", "second"])
        #expect(lines.map(\.isCommitted) == [true, true, true, false])
        #expect(lines[0].author == "Test" && lines[0].date == first.authorDate)

        let before = try await repo.repository.blame(path: "a.txt", at: first.oid)
        #expect(before.map(\.text) == ["one", "two"] && before.allSatisfy { $0.oid == first.oid })
    }

    @Test func anOlderVersionIsReadAndRestoredUnstaged() async throws {
        let repo = try await TempRepository()
        try repo.write("a b.txt", "old\n")
        try await repo.commitAll("first")
        let first = try #require(try await repo.repository.log(limit: 1).first)
        try repo.write("a b.txt", "new\n")
        try await repo.commitAll("second")

        #expect(try await repo.repository.fileContents("a b.txt", at: first.oid) == Data("old\n".utf8))
        _ = try await repo.repository.restore("a b.txt", from: first.oid)
        #expect(try repo.read("a b.txt") == "old\n")
        let status = try await repo.repository.status()
        #expect(status.unstagedCount == 1 && status.stagedCount == 0)
    }

    // MARK: - Phase 4: branches and tags

    @Test func mergeFastForwardsWhenItCanAndOtherwiseStagesForTheComposer() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("one")
        try await repo.run("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("feature")
        try await repo.run("switch", "-q", "main")

        #expect(try await repo.repository.canFastForward(to: "feature"))
        _ = try await repo.repository.merge("feature", fastForward: true)
        #expect(try await repo.repository.status().head.oid == (try await repo.run("rev-parse", "feature")).trimmingCharacters(in: .newlines))

        try await repo.run("switch", "-q", "-c", "other", "HEAD~1")
        try repo.write("o.txt", "o\n")
        try await repo.commitAll("other")
        try await repo.run("switch", "-q", "main")
        #expect(try await repo.repository.canFastForward(to: "other") == false)
        _ = try await repo.repository.merge("other", fastForward: false)
        var status = try await repo.repository.status()
        #expect(status.state == .merging && status.entries.map(\.path) == ["o.txt"] && status.stagedCount == 1)

        _ = try await repo.repository.commit("+ Update +\n - Merge other into main\n")
        status = try await repo.repository.status()
        let merge = try #require(try await repo.repository.log(limit: 1).first)
        #expect(status.state == .normal && merge.isMerge && merge.message == "+ Update +\n - Merge other into main")
    }

    @Test func tagsAreListedNewestFirstDeletedRenamedBranchAndPushed() async throws {
        let remote = try await TempRepository(bare: true)
        let repo = try await TempRepository(cloning: remote)
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("first commit")
        let head = try #require(try await repo.repository.log(limit: 1).first)
        try await repo.run("push", "-q", "origin", "main")
        _ = try await repo.repository.createTag("light", at: head.oid)
        _ = try await repo.repository.createTag("v1.0", at: head.oid, message: "Release one\n\nDetails")

        let tags = try await repo.repository.tags()
        #expect(Set(tags.map(\.name)) == ["light", "v1.0"] && tags.allSatisfy { $0.oid == head.oid && $0.date != nil })
        #expect(tags.first { $0.name == "v1.0" }?.subject == "Release one")
        #expect(tags.first { $0.name == "light" }?.subject == "first commit")

        _ = try await repo.repository.pushTag("v1.0")
        #expect(try await remote.run("tag") == "v1.0\n")
        _ = try await repo.repository.pushTag(nil)
        #expect(try await remote.run("tag") == "light\nv1.0\n")

        _ = try await repo.repository.deleteTag("light")
        #expect(try await repo.repository.tags().map(\.name) == ["v1.0"])
        #expect(try await remote.run("tag") == "light\nv1.0\n")

        _ = try await repo.repository.renameBranch("main", to: "trunk")
        #expect(try await repo.repository.status().head.branch == "trunk")
    }

    // MARK: - Phase 5: stashes and comparing

    @Test func aStashsFilesAndDiffsUntrackedOnesTooAndApplyKeepsIt() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("one")
        try repo.write("a.txt", "a\nchanged\n")
        try repo.write("new.txt", "new\n")
        _ = try await repo.repository.stashPush(message: "work")
        let stash = try #require(try await repo.repository.stashes().first)

        let files = try await repo.repository.stashFiles(stash)
        #expect(files.tracked.map(\.path) == ["a.txt"] && files.tracked[0].change == .modified)
        #expect(files.untracked.map(\.path) == ["new.txt"] && files.untracked[0].change == .added)
        let tracked = try await repo.repository.diff(path: "a.txt", area: .commit(stash.ref))
        #expect(tracked?.hunks.first?.lines.contains { $0.text == "changed" } == true)
        let untracked = try await repo.repository.diff(path: "new.txt", area: .commit(GitRepository.untrackedRevision(of: stash)))
        #expect(untracked?.hunks.first?.lines.map(\.text) == ["new"])

        _ = try await repo.repository.stashApply(stash)
        #expect(try repo.read("new.txt") == "new\n")
        #expect(try await repo.repository.stashes().count == 1)

        // A stash without untracked files has no third parent.
        _ = try await repo.repository.stashPush(message: "")
        try await repo.run("stash", "drop", "-q", "stash@{0}")
        try repo.write("a.txt", "only tracked\n")
        try await repo.run("stash", "push", "-q")
        let plain = try #require(try await repo.repository.stashes().first)
        #expect(try await repo.repository.stashFiles(plain).untracked.isEmpty)
    }

    @Test func aCommitsVersionIsComparedWithTheWorkingCopy() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("one")
        let one = try #require(try await repo.repository.log(limit: 1).first)
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("two")
        try repo.write("a.txt", "three\n")

        let diff = try #require(try await repo.repository.diff(path: "a.txt", area: .workingCopy(since: one.oid)))
        let lines = diff.hunks.flatMap(\.lines).map(\.text)
        #expect(lines == ["one", "three"])
    }
}

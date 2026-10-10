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
}

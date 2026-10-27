import Foundation
import Testing
@testable import SourceDeckCore

struct CommitGraphTests {
    private func commit(_ oid: String, _ parents: String...) -> Commit {
        Commit(oid: oid, parents: parents, authorName: "", authorEmail: "", authorDate: .now, commitDate: .now, refs: [], message: oid)
    }

    private func line(_ half: CommitGraph.Line.Half, _ from: Int, _ to: Int, _ color: Int) -> CommitGraph.Line {
        CommitGraph.Line(half: half, from: from, to: to, color: color)
    }

    @Test func aLinearHistoryIsOneLane() {
        let rows = CommitGraph.layout([commit("c", "b"), commit("b", "a"), commit("a")])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.color) == [0, 0, 0])
        #expect(rows.map(\.width) == [1, 1, 1])
        #expect(rows[0].lines == [line(.lower, 0, 0, 0)])
        #expect(rows[1].lines == [line(.upper, 0, 0, 0), line(.lower, 0, 0, 0)])
        #expect(rows[2].lines == [line(.upper, 0, 0, 0)])
    }

    /// m merges b (main) and f (feature), both from a.
    @Test func aMergeOpensALaneThatEndsAtTheForkPoint() {
        let rows = CommitGraph.layout([commit("m", "b", "f"), commit("f", "a"), commit("b", "a"), commit("a")])
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        #expect(rows.map(\.color) == [0, 1, 0, 0])
        #expect(rows.map(\.width) == [2, 2, 2, 2])
        #expect(rows[0].lines == [line(.lower, 0, 1, 1), line(.lower, 0, 0, 0)])
        #expect(rows[1].lines == [line(.upper, 0, 0, 0), line(.upper, 1, 1, 1), line(.lower, 0, 0, 0), line(.lower, 1, 1, 1)])
        #expect(rows[3].lines == [line(.upper, 0, 0, 0), line(.upper, 1, 0, 1)])
    }

    /// Every branch: two tips and the lanes they leave free for the next.
    @Test func eachTipStartsInTheFirstFreeLane() {
        let rows = CommitGraph.layout([commit("x", "a"), commit("y", "a"), commit("a"), commit("z", "w"), commit("w")])
        #expect(rows.map(\.lane) == [0, 1, 0, 0, 0])
        #expect(rows.map(\.color) == [0, 1, 0, 2, 2])
        #expect(rows[1].lines == [line(.upper, 0, 0, 0), line(.lower, 0, 0, 0), line(.lower, 1, 1, 1)])
        #expect(rows[2].lines == [line(.upper, 0, 0, 0), line(.upper, 1, 0, 1)])
        #expect(rows[3].lines == [line(.lower, 0, 0, 2)])
    }

    /// A merge whose other parent a lane already waits for joins that lane.
    @Test func aMergeJoinsTheLaneWaitingForItsParent() {
        let rows = CommitGraph.layout([commit("t", "f"), commit("m", "b", "f"), commit("f", "a"), commit("b", "a"), commit("a")])
        #expect(rows.map(\.lane) == [0, 1, 0, 1, 0])
        #expect(rows[1].lines == [line(.upper, 0, 0, 0), line(.lower, 1, 0, 0), line(.lower, 0, 0, 0), line(.lower, 1, 1, 1)])
    }

    @Test func logOfEveryBranchPutsEachCommitBeforeItsParents() async throws {
        let repo = try await TempRepository()
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("one")
        try await repo.run("switch", "-q", "-c", "feature")
        try repo.write("f.txt", "f\n")
        try await repo.commitAll("feature")
        try await repo.run("switch", "-q", "main")
        try repo.write("a.txt", "b\n")
        try await repo.commitAll("two")
        try await repo.run("tag", "v1")

        let head = try await repo.repository.log()
        let all = try await repo.repository.log(allBranches: true)
        #expect(head.map(\.summary) == ["two", "one"])
        #expect(Set(all.map(\.summary)) == ["two", "feature", "one"])
        for (index, commit) in all.enumerated() {
            #expect(commit.parents.allSatisfy { parent in all.firstIndex { $0.oid == parent }! > index })
        }
    }
}

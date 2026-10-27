import Foundation

/// History's graph, row by row: the lane of each commit and the lines from
/// it to its parents. The commits come newest first, each before its
/// parents (`log` reads them with `--date-order`).
///
/// A lane waits for one commit, the parent of the commit above it. A
/// commit takes the first lane waiting for it, or the first free lane when
/// none is (a branch's tip); the other lanes waiting for it end there. Its
/// first parent carries on in its lane; another parent joins the lane
/// already waiting for it, or starts a new one. A lane keeps its colour
/// from start to end.
public enum CommitGraph {
    public struct Row: Sendable, Equatable {
        /// The commit's lane, from 0 at the left.
        public let lane: Int
        public let color: Int
        public let lines: [Line]
        /// How many lanes the row reaches.
        public let width: Int
    }

    /// A line in the upper half of a row (from its top to the commit) or
    /// the lower half (from the commit to its bottom), between two lanes.
    public struct Line: Sendable, Equatable {
        public enum Half: Sendable { case upper, lower }

        public let half: Half
        public let from: Int
        public let to: Int
        /// Of the lane the line belongs to: the lane coming in, or the
        /// lane of the parent going out.
        public let color: Int
    }

    public static func layout(_ commits: [Commit]) -> [Row] {
        var lanes: [(oid: String, color: Int)?] = []
        var colors = 0
        func newColor() -> Int {
            defer { colors += 1 }
            return colors
        }
        func freeLane() -> Int {
            if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
            lanes.append(nil)
            return lanes.count - 1
        }

        return commits.map { commit in
            var lines: [Line] = []
            let lane = lanes.firstIndex { $0?.oid == commit.oid } ?? freeLane()
            let color = lanes[lane]?.color ?? newColor()
            for (index, waiting) in lanes.enumerated() {
                guard let waiting else { continue }
                if waiting.oid == commit.oid {
                    lines.append(Line(half: .upper, from: index, to: lane, color: waiting.color))
                    lanes[index] = nil
                } else {
                    lines.append(Line(half: .upper, from: index, to: index, color: waiting.color))
                }
            }
            lanes[lane] = commit.parents.first.map { ($0, color) }
            var started: Set<Int> = []
            for parent in commit.parents.dropFirst() {
                if let joined = lanes.firstIndex(where: { $0?.oid == parent }) {
                    lines.append(Line(half: .lower, from: lane, to: joined, color: lanes[joined]!.color))
                } else {
                    let new = freeLane()
                    lanes[new] = (parent, newColor())
                    started.insert(new)
                    lines.append(Line(half: .lower, from: lane, to: new, color: lanes[new]!.color))
                }
            }
            // A lane started here comes out of the commit, not down from it.
            for (index, waiting) in lanes.enumerated() where !started.contains(index) {
                if let waiting { lines.append(Line(half: .lower, from: index, to: index, color: waiting.color)) }
            }
            while lanes.last.map({ $0 == nil }) == true { lanes.removeLast() }
            let width = lines.reduce(lane + 1) { max($0, $1.from + 1, $1.to + 1) }
            return Row(lane: lane, color: color, lines: lines, width: width)
        }
    }
}

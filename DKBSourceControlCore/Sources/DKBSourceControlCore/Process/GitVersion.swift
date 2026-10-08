import Foundation

/// `git version 2.54.0 (Apple Git-157)` → 2.54.0.
public struct GitVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// `status --porcelain=v2`, `switch`/`restore` and
    /// `for-each-ref %(upstream:track)` are all older than this.
    public static let minimumSupported = GitVersion(major: 2, minor: 30, patch: 0)

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing text: String) {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        let numbers = text[range].split(separator: ".").compactMap { Int($0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public var isSupported: Bool { self >= Self.minimumSupported }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

import Foundation
import Testing
@testable import DKBSourceControlCore

@Suite struct GitIgnoreTests {
    @Test(arguments: [
        ("deploy/.env", "/deploy/.env"),
        ("we*ird [1]?.txt", #"/we\*ird \[1]\?.txt"#),
        (#"back\slash"#, #"/back\\slash"#),
        ("#hash", "/#hash"),
        ("!bang", "/!bang"),
        ("tr  ", #"/tr\ \ "#),
        ("Cà Phê Tý Mập.txt", "/Cà Phê Tý Mập.txt"),
    ])
    func pattern(path: String, expected: String) {
        #expect(GitIgnore.pattern(for: path) == expected)
    }

    /// git itself agrees each pattern matches its file and nothing else.
    @Test func appendedPatternsIgnoreExactlyThoseFiles() async throws {
        let repo = try await TempRepository()
        let names = ["deploy/.env", "we*ird [1]?.txt", "#hash", "!bang", "tr  ", "Cà Phê.txt"]
        for name in names { try repo.write(name, "x") }
        try repo.write("weXird 1a.txt", "x")
        try repo.write(".gitignore", "*.tmp")
        for name in names { try GitIgnore.append(path: name, root: repo.url) }
        // The missing newline at the end was added before the first pattern.
        #expect(try repo.read(".gitignore").hasPrefix("*.tmp\n/deploy/.env\n"))
        let untracked = try await repo.repository.status().entries.map(\.path)
        #expect(Set(untracked) == [".gitignore", "weXird 1a.txt"])
    }

    @Test func appendCreatesTheFile() async throws {
        let repo = try await TempRepository()
        try repo.write("a.log", "x")
        try GitIgnore.append(path: "a.log", root: repo.url)
        #expect(try repo.read(".gitignore") == "/a.log\n")
    }
}

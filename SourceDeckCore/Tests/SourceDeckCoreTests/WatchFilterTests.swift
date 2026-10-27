import Foundation
import Testing
@testable import SourceDeckCore

@Suite struct WatchFilterTests {
    private let filter = WatchFilter(root: "/Users/x/MyWebsite", gitDirectory: "/Users/x/MyWebsite/.git",
                                     ignoredDirectories: ["MyWebsiteAPI/bin/", "node_modules/", ".build/"])

    @Test(arguments: [
        ["/Users/x/MyWebsite"],
        ["/Users/x/MyWebsite/"],
        ["/Users/x/MyWebsite/src/app"],
        // The index, HEAD and refs live here: a commit or stage from another app.
        ["/Users/x/MyWebsite/.git"],
        ["/Users/x/MyWebsite/.git/refs/heads"],
        // A folder whose name only starts like an ignored one.
        ["/Users/x/MyWebsite/node_modules_backup"],
        ["/Users/x/MyWebsite/.build/debug", "/Users/x/MyWebsite/README"],
    ])
    func relevant(batch: [String]) {
        #expect(filter.isRelevant(batch))
    }

    @Test(arguments: [
        ["/Users/x/MyWebsite/.git/objects/ab"],
        ["/Users/x/MyWebsite/.git/objects"],
        ["/Users/x/MyWebsite/node_modules"],
        ["/Users/x/MyWebsite/node_modules/next/dist/"],
        ["/Users/x/MyWebsite/MyWebsiteAPI/bin/Debug/net9.0", "/Users/x/MyWebsite/.build/debug/x.build"],
        [],
    ])
    func ignored(batch: [String]) {
        #expect(!filter.isRelevant(batch))
    }

    @Test func aNewIgnoredFolderIsFilteredOnceTheListIsReadAgain() {
        var filter = filter
        let build = ["/Users/x/MyWebsite/DerivedData/Build"]
        #expect(filter.isRelevant(build))
        filter.update(ignoredDirectories: ["DerivedData/"])
        #expect(!filter.isRelevant(build))
    }

    /// Real folders from git: what an ignore rule matches itself, not a
    /// folder that merely holds ignored files.
    @Test func ignoredDirectoriesComeFromGit() async throws {
        let repo = try await TempRepository()
        try repo.write(".gitignore", "build/\n*.log\nnode_modules\n")
        try repo.write("build/x/o", "")
        try repo.write("deep/build/z/q", "")
        try repo.write("node_modules/a/b", "")
        try repo.write("src/only.log", "")
        try repo.write("Cà Phê/build/x", "")
        let ignored = try await repo.repository.ignoredDirectories()
        #expect(Set(ignored) == ["build/", "deep/build/", "node_modules/", "Cà Phê/build/"])

        let gitDirectory = try await repo.repository.gitDirectory()
        let filter = WatchFilter(root: repo.url.path, gitDirectory: gitDirectory.path, ignoredDirectories: ignored)
        #expect(!filter.isRelevant([repo.url.appendingPathComponent("Cà Phê/build/x").path]))
        #expect(filter.isRelevant([repo.url.appendingPathComponent("src").path]))
    }
}

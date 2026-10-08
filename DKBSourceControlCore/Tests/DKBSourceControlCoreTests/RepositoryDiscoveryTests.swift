import Foundation
import Testing
@testable import DKBSourceControlCore

@Suite struct RepositoryDiscoveryTests {
    /// Folders containing a `.git` folder are enough: discovery only looks.
    private func makeTree(_ repositories: [String], files: [String: String] = [:]) throws -> URL {
        let root = TempRepository.tempRoot.appendingPathComponent("discover-\(UUID().uuidString)", isDirectory: true)
        for path in repositories {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path).appendingPathComponent(".git"),
                                                    withIntermediateDirectories: true)
        }
        for (path, content) in files {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    private func names(_ urls: [URL], under root: URL) -> [String] {
        urls.map { String($0.path.dropFirst(root.standardizedFileURL.path.count + 1)) }
    }

    @Test func findsRepositoriesOneAndTwoLevelsDownOnly() throws {
        let root = try makeTree(["MyWebsite", "Clients/AcmeGroup", "Clients/Old/Deep", "node_modules/pkg", ".nvm", "Plain/sub"],
                                files: ["notes.txt": "x"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Plain/sub is two levels down and counts; Clients/Old/Deep is three.
        #expect(names(RepositoryDiscovery.discover(in: root), under: root) == ["Clients/AcmeGroup", "MyWebsite", "Plain/sub"])
    }

    @Test func doesNotLookInsideARepository() throws {
        let root = try makeTree(["App", "App/Vendor/lib"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names(RepositoryDiscovery.discover(in: root), under: root) == ["App"])
    }

    @Test func aRepositoryChosenDirectlyIsItself() throws {
        let root = try makeTree(["Repo"])
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("Repo")
        #expect(RepositoryDiscovery.discover(in: repo) == [repo.standardizedFileURL])
    }

    @Test func linkedWorktreeWithAGitFileCounts() throws {
        let root = try makeTree([], files: ["Worktree/.git": "gitdir: /elsewhere/.git/worktrees/w\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(names(RepositoryDiscovery.discover(in: root), under: root) == ["Worktree"])
    }

    @Test func symbolicLinksAreNotFollowed() throws {
        let root = try makeTree(["Real"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root.appendingPathComponent("Real"))
        #expect(names(RepositoryDiscovery.discover(in: root), under: root) == ["Real"])
    }

    /// Scanning home must not trigger the Desktop/Documents/Downloads prompts;
    /// choosing Desktop itself still finds what is there.
    @Test func protectedHomeFoldersAreSkippedOnlyWhenScanningHome() throws {
        let home = try makeTree(["Project", "Desktop/OnDesktop", "Documents/InDocuments"])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(names(RepositoryDiscovery.discover(in: home, homeDirectory: home), under: home) == ["Project"])
        let desktop = home.appendingPathComponent("Desktop")
        #expect(RepositoryDiscovery.discover(in: desktop, homeDirectory: home).map(\.lastPathComponent) == ["OnDesktop"])
    }
}

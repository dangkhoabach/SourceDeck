import Testing
@testable import DKBSourceControlCore

@Suite struct FileTreeTests {
    /// "  name" per row, two spaces per level, folders ending in "/".
    private func outline(_ paths: [String], collapsed: Set<String> = []) -> [String] {
        FileTree.rows(paths, path: { $0 }, collapsed: collapsed).map { row in
            switch row {
            case .folder(let folder, let depth): String(repeating: "  ", count: depth) + folder.name + "/"
            case .file(let path, let depth): String(repeating: "  ", count: depth) + path.split(separator: "/").last!
            }
        }
    }

    @Test func foldersBeforeFilesInFinderOrder() {
        #expect(outline(["b.txt", "a/x.swift", "file10", "file2", "B/y.swift"]) == [
            "a/", "  x.swift",
            "B/", "  y.swift",
            "b.txt", "file2", "file10",
        ])
    }

    @Test func singleChildFoldersAreMerged() {
        let paths = [
            "DKBDownloaderApp/App/AppSettings.swift",
            "DKBDownloaderApp/UI/Home/HomeViewModel.swift",
            "DKBDownloaderApp/UI/Library/LibraryViewModel.swift",
            "DKBDownloaderCore/Sources/DKBDownloaderCore/Domain/DownloadManager.swift",
            "README.md",
        ]
        #expect(outline(paths) == [
            "DKBDownloaderApp/",
            "  App/", "    AppSettings.swift",
            "  UI/",
            "    Home/", "      HomeViewModel.swift",
            "    Library/", "      LibraryViewModel.swift",
            "DKBDownloaderCore/Sources/DKBDownloaderCore/Domain/", "  DownloadManager.swift",
            "README.md",
        ])
    }

    /// A folder with a file of its own keeps its row even with one subfolder.
    @Test func folderWithFilesIsNotMerged() {
        #expect(outline(["a/b/c.txt", "a/d.txt"]) == ["a/", "  b/", "    c.txt", "  d.txt"])
    }

    @Test func collapsedFolderHidesItsContentOnly() {
        let paths = ["src/app/page.tsx", "src/app/layout.tsx", "src/lib/db.ts", "package.json"]
        #expect(outline(paths, collapsed: ["src/app"]) == ["src/", "  app/", "  lib/", "    db.ts", "package.json"])
        #expect(outline(paths, collapsed: ["src"]) == ["src/", "package.json"])
    }

    @Test func folderPathAndItemsCoverEverythingUnderIt() throws {
        let rows = FileTree.rows(["x/y/z/1.txt", "x/y/z/w/2.txt", "x/y/z/w/3.txt"], path: { $0 })
        let folders = rows.compactMap { row -> FileTree.Folder<String>? in
            if case .folder(let folder, _) = row { folder } else { nil }
        }
        #expect(folders.map(\.path) == ["x/y/z", "x/y/z/w"])
        #expect(folders.map(\.name) == ["x/y/z", "w"])
        #expect(Set(try #require(folders.first).items) == ["x/y/z/1.txt", "x/y/z/w/2.txt", "x/y/z/w/3.txt"])
        #expect(Set(folders[1].items) == ["x/y/z/w/2.txt", "x/y/z/w/3.txt"])
    }

    @Test func emptyList() {
        #expect(FileTree.rows([String](), path: { $0 }).isEmpty)
    }
}

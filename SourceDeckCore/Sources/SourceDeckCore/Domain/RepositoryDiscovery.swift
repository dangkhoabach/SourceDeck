import Foundation

/// "Scan folder…": the git work trees at most `maxDepth` levels
/// below a folder.
public enum RepositoryDiscovery {
    /// Never repositories of the user's own: dependencies and build output.
    static let skippedNames: Set<String> = ["node_modules", "Library", "DerivedData", "Pods", "Carthage"]

    /// Scanning the home folder must not walk into the folders macOS guards
    /// with a permission prompt — three dialogs for one click. Choosing one
    /// of them as the folder to scan still works.
    static let protectedHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications"]

    /// Sorted by path. A repository's own subfolders aren't searched;
    /// hidden folders and symbolic links are skipped (`~/.nvm` is a git
    /// clone).
    public static func discover(in root: URL, maxDepth: Int = 2,
                                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        let isHome = root.path == homeDirectory.standardizedFileURL.path
        if isRepository(root, fm: fm) { return [root] }

        var found: [URL] = []
        var level = [root]
        for depth in 1...max(1, maxDepth) {
            var next: [URL] = []
            for folder in level {
                let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                            options: [.skipsHiddenFiles])) ?? []
                for child in children {
                    let name = child.lastPathComponent
                    guard !skippedNames.contains(name), !(depth == 1 && isHome && protectedHomeFolders.contains(name)),
                          let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    if isRepository(child, fm: fm) {
                        found.append(child.standardizedFileURL)
                    } else {
                        next.append(child)
                    }
                }
            }
            level = next
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// `.git` is a folder in a normal clone and a file in a linked worktree.
    static func isRepository(_ folder: URL, fm: FileManager) -> Bool {
        fm.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }
}

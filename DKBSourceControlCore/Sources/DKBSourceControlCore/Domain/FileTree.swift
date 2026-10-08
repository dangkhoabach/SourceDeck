import Foundation

/// A file list laid out as a tree: one row per folder and per file, in
/// the order they are drawn, each with its depth.
///
/// Folders come before files, both in Finder order ("file2" before
/// "file10"). A folder whose only content is one subfolder is merged into
/// it ("Sources/App/UI"), as Xcode and VS Code do, so deep paths don't
/// cost a row per level. A collapsed folder still has its row; what is
/// under it is left out.
public enum FileTree {
    public struct Folder<Item> {
        /// From the repository root, without a trailing "/".
        public let path: String
        /// One or more merged levels: "Sources/App/UI".
        public let name: String
        /// Every file under it, at any depth.
        public let items: [Item]
    }

    public enum Row<Item> {
        case folder(Folder<Item>, depth: Int)
        case file(Item, depth: Int)
    }

    /// - Parameters:
    ///   - path: the item's path from the repository root, "/"-separated.
    ///   - collapsed: folder paths whose content is hidden.
    public static func rows<Item>(_ items: [Item], path: (Item) -> String, collapsed: Set<String> = []) -> [Row<Item>] {
        let root = Node<Item>()
        for item in items {
            var node = root
            for folder in path(item).split(separator: "/").dropLast() {
                node = node.child(String(folder))
            }
            node.files.append(item)
        }
        var rows: [Row<Item>] = []
        root.emit(into: &rows, prefix: "", depth: 0, collapsed: collapsed, path: path)
        return rows
    }

    private final class Node<Item> {
        var folders: [String: Node] = [:]
        var files: [Item] = []

        func child(_ name: String) -> Node {
            if let node = folders[name] { return node }
            let node = Node()
            folders[name] = node
            return node
        }

        var allFiles: [Item] {
            files + folders.values.flatMap(\.allFiles)
        }

        func emit(into rows: inout [Row<Item>], prefix: String, depth: Int, collapsed: Set<String>, path: (Item) -> String) {
            for key in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                var name = key
                var node = folders[key]!
                while node.files.isEmpty, node.folders.count == 1, let only = node.folders.first {
                    name += "/" + only.key
                    node = only.value
                }
                let folderPath = prefix + name
                rows.append(.folder(Folder(path: folderPath, name: name, items: node.allFiles), depth: depth))
                if !collapsed.contains(folderPath) {
                    node.emit(into: &rows, prefix: folderPath + "/", depth: depth + 1, collapsed: collapsed, path: path)
                }
            }
            let sorted = files.sorted {
                (path($0) as NSString).lastPathComponent.localizedStandardCompare((path($1) as NSString).lastPathComponent) == .orderedAscending
            }
            rows += sorted.map { .file($0, depth: depth) }
        }
    }
}

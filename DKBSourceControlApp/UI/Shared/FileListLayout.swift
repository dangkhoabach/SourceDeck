import DKBSourceControlCore
import SwiftUI

/// How the Working Copy and a commit's files are listed: one path per row,
/// or folders that open and close (`FileTree`). One choice for both,
/// kept across launches.
enum FileListLayout: String {
    case list, tree

    /// Width of one tree level, and of the chevron column.
    static let indent: CGFloat = 16
    /// Between the chevron and what follows it in a folder row.
    static let chevronSpacing: CGFloat = 6
}

struct FileListLayoutPicker: View {
    @AppStorage(AppSettings.fileListLayoutKey) private var layout = FileListLayout.list

    var body: some View {
        Picker("Layout", selection: $layout) {
            Image(systemName: "list.bullet")
                .accessibilityLabel(Text("Show as List"))
                .help("Show as List")
                .tag(FileListLayout.list)
            Image(systemName: "list.bullet.indent")
                .accessibilityLabel(Text("Show as Tree"))
                .help("Show as Tree")
                .tag(FileListLayout.tree)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A folder of the tree layout. A click anywhere on it opens or closes
/// it; the count is every file under it, at any depth.
struct FolderRow<Item, Accessory: View>: View {
    let folder: FileTree.Folder<Item>
    let depth: Int
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: FileListLayout.chevronSpacing) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: FileListLayout.indent)
            accessory
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            Text(verbatim: folder.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(folder.items.count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * FileListLayout.indent)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: folder.path))
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityAction(named: isExpanded ? Text("Collapse") : Text("Expand"), toggle)
    }
}

extension FolderRow where Accessory == EmptyView {
    init(folder: FileTree.Folder<Item>, depth: Int, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.init(folder: folder, depth: depth, isExpanded: isExpanded, toggle: toggle) { EmptyView() }
    }
}

extension View {
    /// A file of the tree layout: its level, plus the chevron column a
    /// folder has, so a file and a folder at the same level line up.
    func treeIndent(_ depth: Int) -> some View {
        padding(.leading, CGFloat(depth + 1) * FileListLayout.indent + FileListLayout.chevronSpacing)
    }
}

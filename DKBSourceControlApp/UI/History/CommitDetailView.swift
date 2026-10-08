import DKBSourceControlCore
import SwiftUI

/// One commit (plan F6): who, when, the whole message, the files it
/// changed (a merge against its first parent) and a read-only diff.
struct CommitDetailView: View {
    @Bindable var history: HistoryModel
    @AppStorage(AppSettings.fileListLayoutKey) private var layout = FileListLayout.list

    /// The diff follows the file, the commit and the viewer's options.
    private struct DiffKey: Equatable {
        let commit: String?
        let file: String?
        let options: DiffOptions
    }

    var body: some View {
        if let commit = history.selectedCommit {
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    CommitMeta(history: history, commit: commit)
                        .padding(12)
                    Divider()
                    List(selection: $history.selectedFile) {
                        if history.files.isEmpty {
                            // git shows a merge against its first parent (plan D7).
                            Text(commit.isMerge ? "This merge brought in nothing its first parent didn't already have."
                                                : "This commit changed no files.")
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            if layout == .tree {
                                fileTree
                            } else {
                                ForEach(history.files) { file in
                                    CommitFileRow(file: file, showsFolder: true)
                                }
                            }
                        } header: {
                            HStack {
                                Text("Files \(history.files.count)")
                                Spacer()
                                FileListLayoutPicker().controlSize(.small)
                            }
                        }
                    }
                }
                .frame(minHeight: 220, idealHeight: 320)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(verbatim: history.selectedFile ?? "")
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                        DiffOptionsControls(options: Bindable(history.model.workingCopy).diffOptions)
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    Divider()
                    if let diff = history.fileDiff {
                        DiffFileView(file: diff, root: history.model.record.url, actions: nil)
                            // Back to the top for another file, not for other options.
                            .id([history.selection, history.selectedFile])
                    } else {
                        ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass",
                                               description: Text("Select a file to see what this commit changed in it."))
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)
            }
            .task(id: DiffKey(commit: history.selection, file: history.selectedFile, options: history.model.workingCopy.diffOptions)) {
                await history.loadFileDiff()
            }
        } else {
            ContentUnavailableView("No commit selected", systemImage: "clock",
                                   description: Text("Select a commit to see its message and files."))
        }
    }

    /// Folders have no tag: only files can be selected.
    private var fileTree: some View {
        let rows = FileTree.rows(history.files, path: \.path, collapsed: history.collapsedFolders).map { row in
            switch row {
            case .folder(let folder, _): (id: "folder:" + folder.path, row: row)
            case .file(let file, _): (id: file.path, row: row)
            }
        }
        return ForEach(rows, id: \.id) { _, row in
            switch row {
            case .folder(let folder, let depth):
                FolderRow(folder: folder, depth: depth, isExpanded: !history.collapsedFolders.contains(folder.path)) {
                    history.collapsedFolders.formSymmetricDifference([folder.path])
                }
            case .file(let file, let depth):
                CommitFileRow(file: file, showsFolder: false)
                    .treeIndent(depth)
            }
        }
    }
}

/// Status letter and path, or the name alone under its folder in the tree;
/// a rename shows where it came from.
private struct CommitFileRow: View {
    let file: CommitFileChange
    let showsFolder: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusLetter(change: file.change)
            if let original = file.originalPath {
                Text(verbatim: original + " → ").foregroundStyle(.secondary)
            }
            Text(verbatim: showsFolder ? file.path : (file.path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .tag(file.path)
    }
}

private struct CommitMeta: View {
    let history: HistoryModel
    let commit: Commit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: commit.title).font(.headline).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                Menu {
                    CommitMenuItems(history: history, commit: commit)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    Text(verbatim: commit.oid).monospaced().textSelection(.enabled)
                }
                GridRow {
                    Text("Author").foregroundStyle(.secondary)
                    Text(verbatim: "\(commit.authorName) <\(commit.authorEmail)>").textSelection(.enabled)
                }
                GridRow {
                    Text("Date").foregroundStyle(.secondary)
                    Text(commit.authorDate, format: .dateTime.year().month().day().hour().minute())
                }
                if commit.isMerge {
                    GridRow {
                        Text("Parents").foregroundStyle(.secondary)
                        Text(verbatim: commit.parents.map { String($0.prefix(7)) }.joined(separator: " · ")).monospaced()
                    }
                }
                if !commit.decorations.isEmpty {
                    GridRow {
                        Text("Refs").foregroundStyle(.secondary)
                        HStack(spacing: 4) { ForEach(commit.decorations, id: \.self) { RefChip(ref: $0) } }
                    }
                }
            }
            .font(.callout)
            ScrollView {
                Text(verbatim: commit.message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

import AppKit
import DKBSourceControlCore
import SwiftUI

/// Conflicts, Staged and Changes (plan F2): a checkbox moves a file
/// between Staged and Changes, Space does it for the selection, ⌘⌫
/// discards it after asking.
struct ChangeListView: View {
    @Bindable var workingCopy: WorkingCopyModel
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            BranchLine(model: workingCopy.model)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            NativeSearchField(text: $workingCopy.search, placeholder: String(localized: "Filter files", bundle: AppLocale.bundle))
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            list
        }
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
            // A ⌘ shortcut reaches a button, not `onKeyPress`. Only while the
            // list has focus: in a text field ⌘⌫ deletes to the line start.
            Button("Discard Changes…") { workingCopy.requestDiscard(workingCopy.selection) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!listFocused || workingCopy.selection.isEmpty)
                .hidden()
        }
        .confirmationDialog(discardTitle, isPresented: Binding(get: { workingCopy.discardRequest != nil },
                                                               set: { if !$0 { workingCopy.discardRequest = nil } }),
                            presenting: workingCopy.discardRequest) { request in
            Button("Discard", role: .destructive) { Task { await workingCopy.discard(request) } }
        } message: { request in
            if request.includingStaged {
                Text("Staged and unstaged changes both go back to the last commit. New files go to the Trash; the rest can't be undone.")
            } else {
                Text("Unstaged changes are thrown away. New files go to the Trash; the rest can't be undone.")
            }
        }
    }

    private var list: some View {
        let conflicted = workingCopy.entries(.conflicted)
        let staged = workingCopy.entries(.staged)
        let unstaged = workingCopy.entries(.unstaged)
        return List(selection: $workingCopy.selection) {
            if !conflicted.isEmpty {
                Section {
                    rows(conflicted, area: .conflicted)
                } header: {
                    SectionTitle(title: "Conflicts", count: conflicted.count)
                }
            }
            Section {
                rows(staged, area: .staged)
            } header: {
                SectionTitle(title: "Staged", count: staged.count) {
                    Button("Unstage All") { Task { await workingCopy.unstage(staged) } }
                        .disabled(staged.isEmpty)
                }
            }
            Section {
                rows(unstaged, area: .unstaged)
            } header: {
                SectionTitle(title: "Changes", count: unstaged.count) {
                    Button("Stage All") { Task { await workingCopy.stage(unstaged) } }
                        .disabled(unstaged.isEmpty)
                }
            }
        }
        .contextMenu(forSelectionType: WorkingCopyModel.Row.self) { rows in
            menu(for: rows)
        }
        .focused($listFocused)
        .onKeyPress(.space) {
            let rows = workingCopy.selection
            Task { await workingCopy.toggleStage(rows) }
            return .handled
        }
        .overlay {
            if workingCopy.model.status?.isClean == true {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                       description: Text("The working copy matches the last commit."))
            }
        }
    }

    /// Identified by area and path: a partly staged file is in two lists,
    /// and a path alone as the id made both rows look selected.
    private func rows(_ entries: [StatusEntry], area: WorkingCopyModel.Area) -> some View {
        let rows = entries.map { (row: WorkingCopyModel.Row(area: area, path: $0.path), entry: $0) }
        return ForEach(rows, id: \.row) { row, entry in
            ChangeRow(entry: entry, area: area) {
                Task { area == .staged ? await workingCopy.unstage([entry]) : await workingCopy.stage([entry]) }
            }
            .tag(row)
        }
    }

    @ViewBuilder
    private func menu(for rows: Set<WorkingCopyModel.Row>) -> some View {
        let staged = workingCopy.selectedEntries(.staged, in: rows)
        let unstaged = workingCopy.selectedEntries(.unstaged, in: rows)
        let all = rows.compactMap(workingCopy.entry)
        let root = workingCopy.model.record.url
        if !unstaged.isEmpty {
            Button("Stage") { Task { await workingCopy.stage(unstaged) } }
        }
        if !staged.isEmpty {
            Button("Unstage") { Task { await workingCopy.unstage(staged) } }
        }
        if !staged.isEmpty || !unstaged.isEmpty {
            Button("Discard Changes…", role: .destructive) { workingCopy.requestDiscard(rows) }
        }
        if !all.isEmpty {
            Divider()
            Button("Open") {
                all.forEach { NSWorkspace.shared.open(root.appendingPathComponent($0.path)) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(all.map { root.appendingPathComponent($0.path) })
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all.map { root.appendingPathComponent($0.path).path }.joined(separator: "\n"), forType: .string)
            }
        }
        if unstaged.contains(where: \.isUntracked) {
            Divider()
            Button("Add to .gitignore") { Task { await workingCopy.ignore(unstaged) } }
        }
    }

    private var discardTitle: Text {
        guard let request = workingCopy.discardRequest else { return Text(verbatim: "") }
        if request.entries.count == 1 {
            return Text("Discard changes to “\((request.entries[0].path as NSString).lastPathComponent)”?")
        }
        return Text("Discard changes to \(request.entries.count) files, starting with “\((request.entries[0].path as NSString).lastPathComponent)”?")
    }
}

/// "main → origin/main ↑1 ↓2" above the lists.
private struct BranchLine: View {
    let model: RepositoryModel

    var body: some View {
        if let head = model.status?.head {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                BranchLabel(head: head).fontWeight(.medium).lineLimit(1)
                if let upstream = head.upstream {
                    Text("→ \(upstream)").foregroundStyle(.secondary).lineLimit(1)
                }
                SyncCounts(head: head)
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }
}

private struct SectionTitle<Actions: View>: View {
    let title: LocalizedStringKey
    let count: Int
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            Text(title)
            Text(count, format: .number).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            actions
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

extension SectionTitle where Actions == EmptyView {
    init(title: LocalizedStringKey, count: Int) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Checkbox, status letter, then the folder dimmed and the name in bold;
/// a rename shows where it came from. A file that looks like a secret is
/// tinted before it is even staged (plan F4b).
private struct ChangeRow: View {
    let entry: StatusEntry
    let area: WorkingCopyModel.Area
    let toggle: () -> Void

    var body: some View {
        let sensitive = SensitiveChangeScanner.pathRule(for: entry.path) != nil
        HStack(spacing: 6) {
            if area != .conflicted {
                Toggle(isOn: Binding(get: { area == .staged }, set: { _ in toggle() })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(area == .staged ? "Unstage" : "Stage")
            }
            StatusLetter(change: change)
            pathText
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if sensitive {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                    .help("This file looks like a secret: git-rule says it must be ignored, never committed.")
            }
        }
        .listRowBackground(sensitive ? Color.red.opacity(0.1) : nil)
    }

    private var change: FileChange {
        switch area {
        case .conflicted: .unmerged
        case .staged: entry.index
        case .unstaged: entry.isUntracked ? .untracked : entry.workTree
        }
    }

    private var pathText: Text {
        let name = (entry.path as NSString).lastPathComponent
        let folder = (entry.path as NSString).deletingLastPathComponent
        var text = Text(verbatim: "")
        if area == .staged, let original = entry.originalPath {
            text = Text(verbatim: original + " → ").foregroundStyle(.secondary)
        }
        if !folder.isEmpty { text = text + Text(verbatim: folder + "/").foregroundStyle(.secondary) }
        return text + Text(verbatim: name).fontWeight(.medium)
    }
}

/// A/M/D/R/T/C, ? for untracked, U for conflicted.
struct StatusLetter: View {
    let change: FileChange

    var body: some View {
        Text(verbatim: letter)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .help(description)
    }

    private var letter: String {
        switch change {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .unmerged: "U"
        case .unmodified: " "
        }
    }

    private var color: Color {
        switch change {
        case .added, .untracked: .green
        case .modified, .typeChanged: .orange
        case .deleted, .unmerged: .red
        case .renamed, .copied: .blue
        case .unmodified: .secondary
        }
    }

    private var description: LocalizedStringKey {
        switch change {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "New, not tracked yet"
        case .unmerged: "Conflicted"
        case .unmodified: "Unchanged"
        }
    }
}

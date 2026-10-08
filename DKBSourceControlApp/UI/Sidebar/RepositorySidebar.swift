import DKBSourceControlCore
import SwiftUI

/// Dashboard, then the repositories in the user's order (drag to reorder).
/// Dropping folders from Finder adds them.
struct RepositorySidebar: View {
    @Bindable var list: RepositoryList
    @State private var renaming: RepositoryModel?
    @State private var draftName = ""
    @State private var removing: RepositoryModel?

    var body: some View {
        List(selection: $list.selection) {
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(RepositoryList.Selection.dashboard)
            Section("Repositories") {
                ForEach(list.models) { model in
                    RepositoryRow(model: model)
                        .tag(RepositoryList.Selection.repository(model.id))
                        .contextMenu {
                            OpenInMenuItems(model: model)
                            Divider()
                            Button("Rename…") {
                                draftName = model.record.name
                                renaming = model
                            }
                            Button("Remove from List…", role: .destructive) { removing = model }
                        }
                }
                .onMove { list.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await list.add(urls) }
            return !urls.isEmpty
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Add Repository…") { list.chooseFoldersToAdd() }
                    Button("Scan Folder…") { list.isScanSheetPresented = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a repository or scan a folder for repositories")
                Spacer()
            }
            .padding(10)
        }
        .alert("Rename Repository", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") { if let renaming { list.rename(renaming, to: draftName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the folder name.")
        }
        .confirmationDialog("Remove “\(removing?.record.name ?? "")” from the list?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { list.remove(removing) } }
        } message: {
            Text("The folder and its files stay on disk.")
        }
    }
}

private struct RepositoryRow: View {
    let model: RepositoryModel

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.record.name).lineLimit(1)
                if let head = model.status?.head {
                    BranchLabel(head: head)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model.runningOperation != nil {
                ProgressView().controlSize(.mini)
            } else if model.refreshError != nil || model.operationError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let status = model.status {
                SyncCounts(head: status.head)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !status.isClean {
                    ChangeCountBadge(status: status)
                }
            }
        }
    }
}

/// How many files have uncommitted changes, each counted once (a partly
/// staged file is one). Red with a conflict, green when everything is
/// staged and ready to commit, orange otherwise; the tooltip splits the
/// count the way the Dashboard does. Solid, so it stays readable on the
/// selected row.
private struct ChangeCountBadge: View {
    let status: RepositoryStatus

    var body: some View {
        let count = status.entries.count
        Text(verbatim: count > 999 ? "999+" : String(count))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 15)
            .background(color, in: Capsule())
            // A narrow sidebar shortens the name, never the count.
            .fixedSize()
            .help(summary)
            .accessibilityLabel(summary)
    }

    private var color: Color {
        if status.hasConflicts { return .red }
        return status.unstagedCount == 0 && status.untrackedCount == 0 ? .green : .orange
    }

    private var summary: String {
        let conflicts = status.entries.count(where: \.isConflict)
        var parts: [String] = []
        if conflicts > 0 { parts.append(String(localized: "\(conflicts) conflicted", bundle: AppLocale.bundle)) }
        if status.stagedCount > 0 { parts.append(String(localized: "\(status.stagedCount) staged", bundle: AppLocale.bundle)) }
        if status.unstagedCount > 0 { parts.append(String(localized: "\(status.unstagedCount) changed", bundle: AppLocale.bundle)) }
        if status.untrackedCount > 0 { parts.append(String(localized: "\(status.untrackedCount) new", bundle: AppLocale.bundle)) }
        return parts.joined(separator: ", ")
    }
}

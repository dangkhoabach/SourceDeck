import AppKit
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
                AddMenuButton(list: list)
                    .fixedSize()
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

/// "+ Add" under the list, an AppKit button that opens its menu itself.
///
/// With a second display to the left (this Mac: the built-in screen at
/// x −1800), macOS 27 places a menu whose left edge comes within about 11 pt
/// of the screen's left edge on the other display's coordinates: it answers
/// the mouse by the button but is drawn 1800 pt to the right. A window at
/// full width puts this button at x = 10, so the menu is moved right when it
/// would start that close to the edge. SwiftUI's `Menu` and a pull-down
/// `NSPopUpButton` both failed there.
private struct AddMenuButton: NSViewRepresentable {
    let list: RepositoryList

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    /// Titles are set on every update, so a language change in Settings shows here.
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.list = list
        button.title = String(localized: "Add", bundle: AppLocale.bundle)
        button.toolTip = String(localized: "Clone a repository, add one from disk or scan a folder for repositories", bundle: AppLocale.bundle)
    }

    func makeCoordinator() -> Coordinator { Coordinator(list: list) }

    @MainActor
    final class Coordinator: NSObject {
        var list: RepositoryList
        /// The menu's left edge stays at least this far from its screen's left edge.
        static let edgeMargin: CGFloat = 20

        init(list: RepositoryList) { self.list = list }

        @objc func open(_ sender: NSButton) {
            let menu = NSMenu()
            for (name, action) in [
                (String(localized: "Clone Repository…", bundle: AppLocale.bundle), #selector(clone)),
                (String(localized: "Add Repository…", bundle: AppLocale.bundle), #selector(add)),
                (String(localized: "Scan Folder…", bundle: AppLocale.bundle), #selector(scan)),
            ] {
                let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            var shift: CGFloat = 0
            if let window = sender.window, let screen = window.screen {
                let left = window.convertToScreen(sender.convert(sender.bounds, to: nil)).minX
                shift = max(0, screen.frame.minX + Self.edgeMargin - left)
            }
            // Under the button; AppKit moves it above when there's no room.
            menu.popUp(positioning: nil, at: NSPoint(x: shift, y: sender.isFlipped ? sender.bounds.height + 4 : -4), in: sender)
        }

        @objc func clone() { list.isCloneSheetPresented = true }
        @objc func add() { list.chooseFoldersToAdd() }
        @objc func scan() { list.isScanSheetPresented = true }
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

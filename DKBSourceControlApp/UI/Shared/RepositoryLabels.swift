import DKBSourceControlCore
import SwiftUI

/// "main", "main (no commits yet)" or "Detached HEAD at 1a2b3c4".
struct BranchLabel: View {
    let head: BranchHead

    var body: some View {
        if let branch = head.branch {
            if head.isUnborn {
                Text("\(branch) (no commits yet)")
            } else {
                Text(branch)
            }
        } else {
            Text("Detached HEAD at \(String(head.oid?.prefix(7) ?? ""))")
        }
    }
}

/// "↑2 ↓1" against the upstream; nothing when level, "no upstream" when
/// the branch was never published.
struct SyncCounts: View {
    let head: BranchHead

    var body: some View {
        if head.upstream == nil {
            if !head.isUnborn && !head.isDetached {
                Text("not published").foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                if head.ahead > 0 { Text("↑\(head.ahead)").help("Commits to push") }
                if head.behind > 0 { Text("↓\(head.behind)").help("Commits to pull") }
            }
            .monospacedDigit()
        }
    }
}

/// Counts of staged, changed, untracked and conflicted files as small
/// coloured capsules; "Clean" when there is nothing.
struct ChangeCounts: View {
    let status: RepositoryStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isClean {
                Text("Clean").foregroundStyle(.secondary)
            }
            let conflicts = status.entries.count(where: \.isConflict)
            if conflicts > 0 { capsule("\(conflicts) conflicted", .red) }
            if status.stagedCount > 0 { capsule("\(status.stagedCount) staged", .green) }
            if status.unstagedCount > 0 { capsule("\(status.unstagedCount) changed", .orange) }
            if status.untrackedCount > 0 { capsule("\(status.untrackedCount) new", .blue) }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func capsule(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A merge, rebase or other operation git left half done (plan D17).
struct StateBadge: View {
    let state: RepositoryState

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var text: LocalizedStringKey? {
        switch state {
        case .normal: nil
        case .merging: "Merging"
        case .rebasing: "Rebasing"
        case .cherryPicking: "Cherry-picking"
        case .reverting: "Reverting"
        case .bisecting: "Bisecting"
        }
    }
}

/// The plain-language hint above git's own message, with a way to the log.
struct GitErrorBanner: View {
    let error: Error
    var showLog: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(GitErrorText.hint(for: error)).fontWeight(.medium)
                Text(GitErrorText.output(of: error))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let showLog { Button("Show Log", action: showLog) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Reveal in Finder, the installed terminals, editors and git clients, and
/// the repository on GitHub — for menus and context menus.
struct OpenInMenuItems: View {
    let model: RepositoryModel

    var body: some View {
        Button("Show in Finder") { ExternalApp.revealInFinder(model.record.url) }
        ForEach(ExternalApp.installed) { app in
            Button {
                app.open(model.record.url)
            } label: {
                Label { Text("Open in \(app.name)") } icon: { Image(nsImage: app.icon) }
            }
        }
        if let url = model.gitHubURL {
            Link("Open on GitHub", destination: url)
        }
    }
}

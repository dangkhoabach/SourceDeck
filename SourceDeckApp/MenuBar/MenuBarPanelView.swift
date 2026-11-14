import SourceDeckCore
import SwiftUI

/// The menu bar panel, laid out as in the author's other menu bar apps: a
/// header, the repositories with their branch and changes, and a footer with
/// the app-level actions. A repository opens in the main window.
struct MenuBarPanelView: View {
    static let width: CGFloat = 360
    /// Past this many, the rest are counted, not listed.
    static let listedLimit = 8

    @AppStorage(AppLocale.key) private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        // The panel is not part of a SwiftUI scene, so the in-app language is
        // applied here rather than inherited.
        MenuBarPanelContent()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
            .frame(width: Self.width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                StatusBarController.shared.fitPanel(height: height)
            }
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MenuBarPanelContent: View {
    private var models: [RepositoryModel] { AppServices.shared.repositories?.models ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "SourceDeck").font(.headline)
                Spacer()
                let changed = models.count(where: { !($0.status?.isClean ?? true) })
                if changed > 0 {
                    Text("\(changed) with changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()
            repositories
            Divider()
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var repositories: some View {
        if models.isEmpty {
            Label("No repositories yet", systemImage: "folder")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 2) {
                ForEach(models.prefix(MenuBarPanelView.listedLimit)) { model in
                    RepositoryRow(model: model)
                }
                if models.count > MenuBarPanelView.listedLimit {
                    Text("And \(models.count - MenuBarPanelView.listedLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("Show SourceDeck", systemImage: "macwindow") { WindowPresenter.showMainWindow() }
            footerButton("Settings…", systemImage: "gearshape") { WindowPresenter.showSettings() }
            footerButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { AppUpdater.checkForUpdates() }
            Spacer()
            footerButton("Quit SourceDeck", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// One repository: its picture, name, branch, ahead and behind, and how many
/// files changed.
private struct RepositoryRow: View {
    let model: RepositoryModel
    @State private var isHovered = false

    var body: some View {
        Button {
            StatusBarController.shared.closePanel()
            WindowPresenter.show(repositoryID: model.id)
        } label: {
            HStack(spacing: 8) {
                RepositoryAvatar(model: model, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.record.name).lineLimit(1)
                    if let head = model.status?.head {
                        HStack(spacing: 6) {
                            Text(verbatim: head.branch ?? String(head.oid?.prefix(7) ?? ""))
                            if head.ahead > 0 { Text(verbatim: "↑\(head.ahead)") }
                            if head.behind > 0 { Text(verbatim: "↓\(head.behind)") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let status = model.status, !status.isClean {
                    Text("\(status.entries.count) changed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

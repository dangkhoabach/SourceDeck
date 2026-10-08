import DKBSourceControlCore
import SwiftUI

/// Main window: repositories sidebar | working copy / history | diff (plan §7.1).
/// The three columns are placeholders until Phase 3 fills them.
struct ContentView: View {
    private let services = AppServices.shared

    var body: some View {
        NavigationSplitView {
            List {
                Label("Dashboard", systemImage: "square.grid.2x2")
                Section("Repositories") {
                    Text("No repositories yet")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } content: {
            ContentUnavailableView("Select a repository", systemImage: "arrow.triangle.branch")
                .navigationSplitViewColumnWidth(min: 380, ideal: 480)
        } detail: {
            StartupStatusView(git: services.git, databaseError: services.database.failure)
        }
        .frame(minWidth: 1100, minHeight: 700)
    }
}

/// What stops the app from working, said plainly — or nothing once git is
/// ready and the database is open.
private struct StartupStatusView: View {
    let git: AppServices.GitState
    let databaseError: Error?

    var body: some View {
        if let databaseError {
            ContentUnavailableView {
                Label("The repository list can't be opened", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(databaseError.localizedDescription)
            }
        } else {
            switch git {
            case .resolving:
                ProgressView("Looking for git…")
            case .ready:
                ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass")
            case .unsupported(let version):
                ContentUnavailableView {
                    Label("git \(version.description) is too old", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("DKB Source Control needs git \(GitVersion.minimumSupported.description) or later. Update Xcode or the Command Line Tools.")
                }
            case .unavailable(let path):
                ContentUnavailableView {
                    Label("git not found", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Nothing at \(path) answered `git --version`. Install the Command Line Tools with `xcode-select --install`.")
                }
            }
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

import AppKit
import DKBSourceControlCore
import SwiftUI

/// The main window once git and the database are ready; until then, what
/// is missing, said plainly.
struct ContentView: View {
    private let services = AppServices.shared

    var body: some View {
        Group {
            if let list = services.repositories {
                MainWindowView(list: list)
            } else {
                StartupStatusView(git: services.git, databaseError: services.database.failure)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
    }
}

/// Sidebar of repositories | the dashboard or one repository (plan §7.1),
/// with the operation log as an inspector.
private struct MainWindowView: View {
    @Bindable var list: RepositoryList
    @AppStorage("showsOperationLog") private var showsLog = false

    var body: some View {
        NavigationSplitView {
            RepositorySidebar(list: list)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let model = list.selectedModel {
                RepositoryView(model: model, showsLog: $showsLog)
            } else {
                DashboardView(list: list)
            }
        }
        .inspector(isPresented: $showsLog) {
            OperationLogView(log: list.log)
                .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsLog.toggle()
                } label: {
                    Label("Log", systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .help("Show or hide the git output of fetch, pull and push (⌥⌘L)")
            }
        }
        .sheet(isPresented: $list.isScanSheetPresented) {
            ScanFolderSheet(list: list)
        }
        .alert("Not a git repository", isPresented: Binding(get: { !list.rejectedFolders.isEmpty },
                                                            set: { if !$0 { list.rejectedFolders = [] } })) {
            Button("OK") {}
        } message: {
            Text(list.rejectedFolders.joined(separator: ", "))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from the editor or Terminal is when things changed.
            Task { await list.refreshAll() }
        }
    }
}

/// Shown instead of the window's content while git is looked for, or when
/// git or the database can't be used.
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
            case .resolving, .ready:
                ProgressView("Looking for git…")
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

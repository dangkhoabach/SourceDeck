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
        // No minimum width here: a fixed one, smaller than what the columns
        // need, let them run past the window's edges. The split view adds up
        // its columns' own.
        .frame(minHeight: 700)
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
            Group {
                if let model = list.selectedModel {
                    RepositoryView(model: model, showsLog: $showsLog)
                } else {
                    DashboardView(list: list)
                }
            }
            // The widest tab's own minimum (History), so the window keeps its
            // size from tab to tab. With the sidebar and the git output at
            // their usual widths it all fits a 1280-point-wide screen.
            .frame(minWidth: 680)
        }
        .inspector(isPresented: $showsLog) {
            OperationLogView(log: list.log)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsLog.toggle()
                } label: {
                    Label("Log", systemImage: "list.bullet.rectangle")
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .help("Show or hide the git output of fetch, pull, push and commit (⌥⌘L)")
            }
        }
        .sheet(isPresented: $list.isScanSheetPresented) {
            ScanFolderSheet(list: list)
        }
        .sheet(isPresented: $list.isCloneSheetPresented) {
            CloneSheet(list: list)
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            (notification.object as? NSWindow)?.moveBackOnScreen()
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

private extension NSWindow {
    /// Showing the git output or the sidebar when the content has no room
    /// left widens the window by that column, past the screen's edge when
    /// the window is near it. Moves it left until it fits again, unless the
    /// user is resizing it or its right edge is on another display.
    func moveBackOnScreen() {
        guard !inLiveResize, !styleMask.contains(.fullScreen), let visible = screen?.visibleFrame,
              frame.maxX > visible.maxX,
              !NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: frame.maxX - 1, y: frame.maxY - 1)) })
        else { return }
        setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - frame.width), y: frame.minY))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

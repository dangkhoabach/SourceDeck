import AppKit
import DKBSourceControlCore
import SwiftUI

/// "Scan Folder…": every repository up to two levels below a folder (home
/// by default), new ones ticked, already listed ones shown as added.
struct ScanFolderSheet: View {
    let list: RepositoryList
    @Environment(\.dismiss) private var dismiss
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var found: [URL] = []
    @State private var chosen: Set<URL> = []
    @State private var isScanning = true

    private var listedPaths: Set<String> { Set(list.models.map(\.record.path)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Folder for Repositories").font(.headline)
            HStack {
                Label(folder.path, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Folder…", action: chooseFolder)
            }
            Group {
                if isScanning {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if found.isEmpty {
                    ContentUnavailableView("No repositories found", systemImage: "magnifyingglass",
                                           description: Text("Only folders up to two levels down are searched."))
                } else {
                    List(found, id: \.self) { url in
                        let listed = listedPaths.contains(url.path)
                        Toggle(isOn: Binding(get: { listed || chosen.contains(url) },
                                             set: { if $0 { chosen.insert(url) } else { chosen.remove(url) } })) {
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                Group {
                                    if listed { Text("Already in the list") } else { Text(url.path) }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(listed)
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count) Repositories") {
                    let urls = found.filter(chosen.contains)
                    Task {
                        await list.add(urls, select: false)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task(id: folder) { await scan() }
    }

    private func scan() async {
        isScanning = true
        let folder = folder
        found = await Task.detached { RepositoryDiscovery.discover(in: folder) }.value
        let listed = listedPaths
        chosen = Set(found.filter { !listed.contains($0.path) })
        isScanning = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Scan")
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

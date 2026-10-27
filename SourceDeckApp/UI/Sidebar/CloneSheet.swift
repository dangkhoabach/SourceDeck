import AppKit
import SourceDeckCore
import SwiftUI

/// "Clone Repository…": a URL, the folder to clone into (home until another
/// one is chosen, then the last one) and the new folder's name, taken from
/// the URL until it is edited. The clone is listed and selected when done.
struct CloneSheet: View {
    let list: RepositoryList
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.cloneParentFolderKey) private var parentPath = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var url = ""
    @State private var name = ""
    @State private var cloning: Task<Void, Never>?
    @State private var error: Error?
    /// git stopped for an account; signed in, the clone runs again from it.
    @State private var signInRequest: RemoteSignIn.Request?
    @State private var clonedAfterSignIn = false

    private var parent: URL { URL(fileURLWithPath: parentPath, isDirectory: true) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var destination: URL { parent.appendingPathComponent(trimmedName, isDirectory: true) }

    /// git clones into a folder that doesn't exist or is empty, nothing else.
    private var destinationIsTaken: Bool {
        guard !trimmedName.isEmpty, FileManager.default.fileExists(atPath: destination.path) else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty != true
    }

    private var nameIsValid: Bool {
        !trimmedName.isEmpty && !trimmedName.contains("/") && trimmedName != "." && trimmedName != ".."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("URL").gridColumnAlignment(.trailing)
                    TextField("URL", text: $url, prompt: Text(verbatim: "https://github.com/owner/repo.git"))
                        .labelsHidden()
                        .onChange(of: url) { old, new in
                            // The name follows the URL until the user types their own.
                            if trimmedName.isEmpty || trimmedName == GitRepository.cloneFolderName(for: old) {
                                name = GitRepository.cloneFolderName(for: new)
                            }
                        }
                }
                GridRow {
                    Text("Clone into")
                    HStack {
                        Label(parent.path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose Folder…", action: chooseParent)
                    }
                }
                GridRow {
                    Text("Folder name")
                    TextField("Folder name", text: $name).labelsHidden()
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Group {
                        if destinationIsTaken {
                            Text("A folder named “\(trimmedName)” already exists here and isn't empty.").foregroundStyle(.red)
                        } else if nameIsValid {
                            Text(verbatim: destination.path).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .disabled(cloning != nil)
            if let error {
                GitErrorBanner(error: error, signIn: { Task { await askToSignIn(after: error) } })
            }
            HStack {
                if cloning != nil {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(.secondary)
                }
                Spacer()
                if let cloning {
                    // Stops git, which removes the half-made folder.
                    Button("Stop") { cloning.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cloning != nil || trimmedURL.isEmpty || !nameIsValid || destinationIsTaken)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(cloning != nil)
        .sheet(item: $signInRequest, onDismiss: { if clonedAfterSignIn { dismiss() } }) { request in
            SignInSheet(request: request, signIn: list.signIn).environment(\.locale, AppLocale.current.locale)
        }
    }

    private func clone() {
        error = nil
        let url = trimmedURL
        let destination = destination
        cloning = Task {
            do {
                try await list.clone(url, into: destination)
                dismiss()
            } catch is CancellationError {
                // Stopped by the user: the sheet stays for another try.
            } catch {
                self.error = error
                await askToSignIn(after: error)
            }
            cloning = nil
        }
    }

    /// Opens Sign In when git stopped for an account; signed in, the same
    /// URL is cloned into the same folder again.
    private func askToSignIn(after error: Error) async {
        let url = trimmedURL
        let destination = destination
        signInRequest = await list.signIn.request(for: error, in: parent) {
            do {
                try await list.clone(url, into: destination)
                self.error = nil
                clonedAfterSignIn = true
                return nil
            } catch {
                self.error = error
                return error
            }
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.prompt = String(localized: "Choose", bundle: AppLocale.bundle)
        if panel.runModal() == .OK, let url = panel.url { parentPath = url.path }
    }
}

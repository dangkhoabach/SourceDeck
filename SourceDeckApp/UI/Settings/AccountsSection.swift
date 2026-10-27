import SwiftUI

/// Settings › Accounts: the HTTP(S) hosts of the
/// listed repositories and who is signed in to each, read from git's
/// credential helper. Sign In and Sign Out go through the helper too, so
/// Terminal sees the same accounts.
struct AccountsSection: View {
    let list: RepositoryList
    @State private var accounts: [RemoteSignIn.Account] = []
    @State private var usesSSH = false
    @State private var isLoading = true
    @State private var request: RemoteSignIn.Request?
    @State private var signingOut: RemoteSignIn.Account?

    var body: some View {
        Section {
            if accounts.isEmpty {
                if isLoading {
                    SkeletonRows(count: 2, secondLine: true, fills: false)
                } else {
                    Text("No repository in the list has an HTTPS remote.").foregroundStyle(.secondary)
                }
            }
            ForEach(accounts) { account in
                LabeledContent {
                    if account.username == nil {
                        Button("Sign In…") {
                            Task { request = await list.signIn.request(url: account.url, in: account.directory) }
                        }
                    } else {
                        Button("Sign Out…") { signingOut = account }
                    }
                } label: {
                    Text(verbatim: account.host)
                    if let username = account.username {
                        Text("Signed in as \(username)")
                    } else {
                        Text("Not signed in")
                    }
                }
            }
            Group {
                Text("Saved by git's credential helper and shared with Terminal.")
                if usesSSH { Text("SSH remotes use your SSH key and agent.") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Accounts")
                Spacer()
                Button { Task { await load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Refresh")
            }
        }
        .task { await load() }
        .sheet(item: $request, onDismiss: { Task { await load() } }) { request in
            SignInSheet(request: request, signIn: list.signIn).environment(\.locale, AppLocale.current.locale)
        }
        .confirmationDialog("Remove the saved account for \(signingOut?.host ?? "")?",
                            isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } })) {
            Button("Sign Out", role: .destructive) {
                guard let account = signingOut, let username = account.username else { return }
                Task {
                    try? await list.signIn.signOut(url: account.url, username: username, in: account.directory)
                    await load()
                }
            }
        } message: {
            Text("Terminal and other git apps use it too.")
        }
    }

    private func load() async {
        isLoading = true
        (accounts, usesSSH) = await list.signIn.accounts(of: list.models.map(\.repository))
        isLoading = false
    }
}

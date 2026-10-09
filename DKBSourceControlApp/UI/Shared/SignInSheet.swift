import AppKit
import DKBSourceControlCore
import SwiftUI

/// The account git stopped for (plan: remote sign-in). Sign In saves it
/// through git's credential helper and runs the command again; when that
/// fails the sheet stays, saying why. The password is cleared as soon as
/// it is sent.
struct SignInSheet: View {
    let signIn: RemoteSignIn
    @State private var request: RemoteSignIn.Request
    @State private var username: String
    @State private var password = ""
    @State private var isSigningIn = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field { case username, password }

    /// Run once in Terminal by the user; the app never changes git's config.
    static let helperCommand = "git config --global credential.helper osxkeychain"

    init(request: RemoteSignIn.Request, signIn: RemoteSignIn) {
        self.signIn = signIn
        _request = State(initialValue: request)
        _username = State(initialValue: request.username)
    }

    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespaces) }
    private var canSubmit: Bool {
        !isSigningIn && !trimmedUsername.isEmpty && !password.isEmpty
            && GitCredential.isValid(trimmedUsername) && GitCredential.isValid(password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign In to \(request.host)").font(.headline)
            if request.reason == .noHelper {
                noHelper
            } else {
                form
            }
            HStack {
                if isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Signing in…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSigningIn)
                if request.reason != .noHelper {
                    Button("Sign In", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isSigningIn)
        .onAppear { focus = username.isEmpty ? .username : .password }
        .onDisappear { password = "" }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            reason
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Username").gridColumnAlignment(.trailing)
                    TextField("Username", text: $username)
                        .labelsHidden()
                        .textContentType(.username)
                        .focused($focus, equals: .username)
                }
                GridRow {
                    Text("Password")
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("Password", text: $password)
                            .labelsHidden()
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                        Text("Password or access token").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isSigningIn)
            if RemoteSignIn.host(of: request.url) == "github.com" {
                HStack(spacing: 6) {
                    Text("GitHub needs a personal access token, not your password.")
                    if let tokens = URL(string: "https://github.com/settings/tokens") {
                        Link("Create a Token…", destination: tokens)
                    }
                }
                .font(.caption)
            }
            if URLComponents(string: request.url)?.scheme?.lowercased() == "http" {
                Label("This connection isn't encrypted.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Saved by git's credential helper (the Keychain on this Mac), the same as signing in from Terminal. DKB Source Control keeps no copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var reason: some View {
        switch request.reason {
        case .missing, .noHelper:
            Text("git needs an account for \(request.url).")
        case .refused:
            Text("The saved account no longer works. Sign in again.")
        case .wrongPassword:
            Label("Wrong username, password or token.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .failed(let output):
            VStack(alignment: .leading, spacing: 4) {
                Label("The account couldn't be saved.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(verbatim: output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var noHelper: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("git needs an account for \(request.url).")
            Text("git has no credential helper to save the account in. Run this in Terminal once, then try again:")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(verbatim: Self.helperCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.helperCommand, forType: .string)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let typed = password
        password = ""
        isSigningIn = true
        Task {
            if let next = await signIn.submit(request, username: trimmedUsername, password: typed) {
                request = next
                isSigningIn = false
                focus = .password
            } else {
                dismiss()
            }
        }
    }
}

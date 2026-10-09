import Foundation

/// An account for an HTTP(S) remote. It goes to the user's own credential
/// helpers (`osxkeychain` on a Mac) through `git credential`, the way git
/// saves one typed in Terminal; the app keeps no copy. The password only
/// ever travels on git's stdin: never in arguments, the environment or a log.
public struct GitCredential: Sendable, Equatable {
    /// As git wrote it, path included: git drops the path unless the user
    /// set `credential.useHttpPath`.
    public let url: String
    public let username: String
    public let password: String

    public init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    /// git's credential format is one `key=value` per line, so a line break
    /// or NUL in a value could add attributes of its own; git refuses them too.
    public static func isValid(_ value: String) -> Bool {
        !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
    }

    func input(includingPassword: Bool = true) throws -> Data {
        var fields = [("url", url), ("username", username)]
        if includingPassword { fields.append(("password", password)) }
        guard fields.allSatisfy({ Self.isValid($0.1) }) else { throw GitCredentialError.lineBreakInValue }
        return Data((fields.map { "\($0)=\($1)\n" }.joined() + "\n").utf8)
    }
}

public enum GitCredentialError: Error, Equatable, Sendable {
    case lineBreakInValue
}

extension GitProcess {
    /// Saves the account in the user's credential helpers.
    public func approve(_ credential: GitCredential, in directory: URL) async throws {
        try await runCredential(["credential", "approve"], input: credential.input(), in: directory)
    }

    /// Removes the account from them: Sign Out, or a password that was just refused.
    public func reject(_ credential: GitCredential, in directory: URL) async throws {
        try await runCredential(["credential", "reject"], input: credential.input(includingPassword: false), in: directory)
    }

    /// The user saved for `url`, or nil when there is none. The password
    /// git hands back is dropped here. Never asks: prompts are off, and
    /// `credential.interactive=false` keeps Git Credential Manager from
    /// opening a window of its own.
    public func savedUsername(for url: String, in directory: URL) async throws -> String? {
        guard GitCredential.isValid(url) else { throw GitCredentialError.lineBreakInValue }
        let result = try await run(["-c", "credential.interactive=false", "credential", "fill"], in: directory,
                                   stdin: Data("url=\(url)\n\n".utf8), readOnly: true)
        guard result.succeeded else { return nil }
        return result.stdoutText.split(separator: "\n").first { $0.hasPrefix("username=") }
            .map { String($0.dropFirst("username=".count)) }
    }

    /// Whether a credential helper would keep an account for `url`. Without
    /// one, `credential approve` succeeds and saves nothing, so a sign-in
    /// would be asked for again and again. The value git uses is the last
    /// one that applies to the URL; an empty one clears the list.
    public func hasCredentialHelper(for url: String, in directory: URL) async throws -> Bool {
        let result = try await run(["config", "--get-urlmatch", "credential.helper", url], in: directory, readOnly: true)
        return result.succeeded && !result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runCredential(_ arguments: [String], input: Data, in directory: URL) async throws {
        let result = try await run(arguments, in: directory, stdin: input)
        guard result.succeeded else { throw GitCommandError(arguments: arguments, result: result) }
    }
}

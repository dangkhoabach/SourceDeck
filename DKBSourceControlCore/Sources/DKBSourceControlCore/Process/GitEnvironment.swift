import Foundation

/// Which `git` to run and the environment every invocation gets (plan §3.2 D5).
///
/// The app never prompts and never opens an editor: credentials come from the
/// helpers the user already configured (`osxkeychain` on this Mac), and when
/// they are missing git fails at once with a readable stderr instead of
/// waiting on a terminal that does not exist (PoC 0.2: 513 ms).
public struct GitEnvironment: Sendable, Equatable {
    public static let defaultGitPath = "/usr/bin/git"

    /// Used when the login shell can't be asked. Enough for git itself and
    /// Homebrew tools; not enough for a hook that needs nvm's `node`.
    public static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

    public enum PathSource: Sendable, Equatable {
        case loginShell
        case fallback
    }

    public let gitURL: URL
    public let path: String
    public let pathSource: PathSource
    let home: String
    let sshAuthSock: String?

    public init(gitPath: String = defaultGitPath, path: String = fallbackPath, pathSource: PathSource = .fallback,
                home: String = NSHomeDirectory(), sshAuthSock: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]) {
        gitURL = URL(fileURLWithPath: gitPath)
        self.path = path
        self.pathSource = pathSource
        self.home = home
        self.sshAuthSock = sshAuthSock
    }

    /// An app started from Finder inherits launchd's minimal PATH, not the
    /// shell's, so a hook calling `node` (installed through nvm, which only
    /// `.zshrc` sets up) would fail with "node: not found". Asking an
    /// interactive login shell once at launch costs ~400 ms (PoC 0.4).
    public static func resolve(gitPath: String = defaultGitPath, shell: String = userShell(),
                               timeout: Duration = .seconds(5)) async -> GitEnvironment {
        if let path = await loginShellPath(shell: shell, timeout: timeout) {
            return GitEnvironment(gitPath: gitPath, path: path, pathSource: .loginShell)
        }
        return GitEnvironment(gitPath: gitPath)
    }

    /// The variables every git process runs with. `readOnly` adds
    /// `GIT_OPTIONAL_LOCKS=0` so a status refresh never rewrites the index
    /// while another tool (Sourcetree, VS Code) has the repository open.
    func variables(readOnly: Bool) -> [String: String] {
        var env = [
            "HOME": home,
            "PATH": path,
            // English messages: GitErrorClassifier matches stderr text.
            "LC_ALL": "en_US.UTF-8",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_EDITOR": "true",
        ]
        if readOnly { env["GIT_OPTIONAL_LOCKS"] = "0" }
        if let sshAuthSock { env["SSH_AUTH_SOCK"] = sshAuthSock }
        return env
    }

    public static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    static let pathMarker = "__DKBSC_PATH__"

    static func loginShellPath(shell: String, timeout: Duration) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(pathMarker)%s\(pathMarker)' \"$PATH\""]
        let output = try? await ProcessRunner.run(process, stdin: nil, timeout: timeout)
        guard let output, output.exitCode == 0 else { return nil }
        return parseMarkedPath(String(decoding: output.stdout, as: UTF8.self))
    }

    /// An interactive shell may print a banner or warnings around the value,
    /// so the PATH is read between markers. A PATH without `/usr/bin` is not
    /// one git can run with, whatever the shell returned.
    static func parseMarkedPath(_ text: String) -> String? {
        let parts = text.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1]
        return path.split(separator: ":").contains("/usr/bin") ? path : nil
    }
}

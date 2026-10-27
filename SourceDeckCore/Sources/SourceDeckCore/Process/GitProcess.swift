import Foundation

public struct GitResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs `git` with the app's fixed environment.
public struct GitProcess: Sendable {
    public let environment: GitEnvironment

    /// `color.ui=never`: output is parsed, never shown raw with escapes.
    /// `core.quotepath=false`: "Cà Phê.txt" stays UTF-8 instead of octal escapes.
    static let globalArguments = ["-c", "color.ui=never", "-c", "core.quotepath=false"]

    public init(environment: GitEnvironment) {
        self.environment = environment
    }

    /// - Parameters:
    ///   - stdin: piped to git, for `commit -F -` and `apply -`.
    ///   - readOnly: the command only reads, so it may skip optional locks.
    ///   - timeout: 30 s fits every local command; network ones pass 120 s.
    public func run(_ arguments: [String], in directory: URL, stdin: Data? = nil, readOnly: Bool = false,
                    timeout: Duration = .seconds(30)) async throws -> GitResult {
        let process = Process()
        process.executableURL = environment.gitURL
        process.arguments = Self.globalArguments + arguments
        process.currentDirectoryURL = directory
        process.environment = environment.variables(readOnly: readOnly)
        let output = try await ProcessRunner.run(process, stdin: stdin, timeout: timeout)
        return GitResult(exitCode: output.exitCode, stdout: output.stdout,
                         stderr: String(decoding: output.stderr, as: UTF8.self))
    }

    /// `git --version`, run from the home folder so it needs no repository.
    public func version() async throws -> GitVersion? {
        let result = try await run(["--version"], in: URL(fileURLWithPath: environment.home), readOnly: true)
        return result.succeeded ? GitVersion(parsing: result.stdoutText) : nil
    }
}

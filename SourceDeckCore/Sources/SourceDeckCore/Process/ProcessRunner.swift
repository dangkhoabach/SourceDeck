import Foundation

struct ProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

/// Runs one `Process` to completion without blocking the caller.
///
/// stdout and stderr are drained as data arrives while the process runs:
/// reading them one after the other deadlocks as soon as the unread one fills
/// its 64 KB pipe buffer (a large `git log` or diff does). Nothing blocks a
/// dispatch thread while it waits: the global queues stop at 64 threads, and
/// a blocking read per pipe used them all once a few dozen git commands ran
/// at once, so the timeout timers and the completions never got a thread.
/// The timeout and task cancellation both terminate the process; neither
/// leaves it running.
enum ProcessRunner {
    static func run(_ process: Process, stdin: Data?, timeout: Duration) async throws -> ProcessOutput {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = stdin.map { _ in Pipe() }
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let state = RunState(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                let group = DispatchGroup()
                group.enter()
                process.terminationHandler = { _ in group.leave() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: GitError.launchFailed(path: process.executableURL?.path ?? "",
                                                                        reason: error.localizedDescription))
                    return
                }
                state.started()

                group.enter()
                drain(stdoutPipe, into: state.appendStdout, then: group.leave)
                group.enter()
                drain(stderrPipe, into: state.appendStderr, then: group.leave)
                if let stdin, let stdinPipe {
                    // A blocking write, on its own thread for the same reason.
                    Thread.detachNewThread {
                        let handle = stdinPipe.fileHandleForWriting
                        // A process that exits before reading all of stdin
                        // (a rejected patch) must not take the app down with
                        // SIGPIPE.
                        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                        try? handle.write(contentsOf: stdin)
                        try? handle.close()
                    }
                }

                let timer = DispatchWorkItem { state.terminate(timedOut: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval, execute: timer)

                group.notify(queue: .global()) {
                    timer.cancel()
                    continuation.resume(with: state.result(exitCode: process.terminationStatus, timeout: timeout))
                }
            }
        } onCancel: {
            state.terminate(timedOut: false)
        }
    }

    /// Reads `pipe` until end of file without holding a thread in between.
    private static func drain(_ pipe: Pipe, into append: @escaping @Sendable (Data) -> Void,
                              then done: @escaping @Sendable () -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                done()
            } else {
                append(chunk)
            }
        }
    }
}

/// Everything the background threads share, behind one lock. `Process` is
/// not `Sendable`; it is only touched here to terminate it.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var stdout = Data()
    private var stderr = Data()
    private var isRunning = false
    private var timedOut = false
    private var cancelled = false

    init(_ process: Process) { self.process = process }

    func started() {
        lock.withLock { isRunning = true }
        // Cancellation can arrive between `run()` and here.
        if lock.withLock({ cancelled }) { process.terminate() }
    }

    func appendStdout(_ data: Data) { lock.withLock { stdout.append(data) } }
    func appendStderr(_ data: Data) { lock.withLock { stderr.append(data) } }

    func terminate(timedOut: Bool) {
        let running = lock.withLock {
            if timedOut { self.timedOut = true } else { cancelled = true }
            return isRunning
        }
        if running, process.isRunning { process.terminate() }
    }

    func result(exitCode: Int32, timeout: Duration) -> Result<ProcessOutput, Error> {
        lock.withLock {
            if cancelled { return .failure(CancellationError()) }
            if timedOut { return .failure(GitError.timedOut(timeout)) }
            return .success(ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr))
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

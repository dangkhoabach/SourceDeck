import CoreServices
import Foundation

/// One FSEvents stream over a repository: folder-level events,
/// no per-file events, the first change delivered at once and the rest
/// gathered for 0.3 s. Which batches matter is `WatchFilter`'s call.
enum RepositoryWatcher {
    /// Batches of changed folder paths until the consuming task ends.
    static func events(paths: [String]) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let sink = Sink(continuation: continuation)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(sink).toOpaque(),
                                               retain: nil, release: { Unmanaged<Sink>.fromOpaque($0!).release() },
                                               copyDescription: nil)
            // `UseCFTypes` makes `paths` a CFArray of CFString; without it they
            // are C strings and reading them as an array crashes.
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info, let batch = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
                Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().continuation.yield(batch)
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
            guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
                continuation.finish()
                return
            }
            let handle = StreamHandle(stream: stream)
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            continuation.onTermination = { _ in handle.stop() }
        }
    }

    private static let queue = DispatchQueue(label: "SourceDeck.RepositoryWatcher")

    private final class Sink: Sendable {
        let continuation: AsyncStream<[String]>.Continuation
        init(continuation: AsyncStream<[String]>.Continuation) { self.continuation = continuation }
    }

    /// The stream is only touched again to stop it, once.
    private final class StreamHandle: @unchecked Sendable {
        let stream: FSEventStreamRef
        init(stream: FSEventStreamRef) { self.stream = stream }

        func stop() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

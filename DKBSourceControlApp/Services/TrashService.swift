import Foundation

/// Discarded files that git can't bring back (untracked, newly added, the
/// new side of a rename) go to the Trash, never through `git clean` or a
/// plain delete (plan D15, Definition of Done 1).
enum TrashService {
    struct Failure: Error {
        let path: String
        let underlying: Error
    }

    /// Paths are relative to `root`; one that is already gone is skipped.
    /// Stops at the first file that can't be moved, so the caller can stop
    /// the rest of the discard too.
    static func moveToTrash(_ paths: [String], in root: URL) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            // Not `fileExists`: it follows symlinks and misses a broken one.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw Failure(path: path, underlying: error)
            }
        }
    }
}

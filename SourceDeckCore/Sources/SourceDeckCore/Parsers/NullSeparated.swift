import Foundation

extension Data {
    /// The fields of `-z` output. Every NUL ends a field, so output ending in
    /// NUL (status, log, stash list) has no empty last field to skip.
    func nullSeparatedFields() -> [String] {
        var fields = split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        return fields
    }
}

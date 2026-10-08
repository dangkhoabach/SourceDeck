import Foundation

/// `git log -z --format=…` (plan D7). Fields are separated by US (0x1f) and
/// commits by NUL. The message is `%B`, the raw message, last because it is
/// the only field that can hold anything.
enum LogParser {
    static let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cI%x1f%D%x1f%B"

    static func parse(_ data: Data) -> [Commit] {
        data.nullSeparatedFields().compactMap { record in
            let fields = record.split(separator: "\u{1f}", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8,
                  let authorDate = try? Date(fields[4], strategy: .iso8601),
                  let commitDate = try? Date(fields[5], strategy: .iso8601) else { return nil }
            var message = fields[7]
            while message.hasSuffix("\n") { message.removeLast() }
            return Commit(
                oid: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                authorName: fields[2],
                authorEmail: fields[3],
                authorDate: authorDate,
                commitDate: commitDate,
                refs: fields[6].isEmpty ? [] : fields[6].components(separatedBy: ", "),
                message: message)
        }
    }
}

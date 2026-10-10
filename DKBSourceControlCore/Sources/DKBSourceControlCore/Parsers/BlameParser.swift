import Foundation

/// `git blame --porcelain`: per line a header "<oid> <original> <final>
/// [<count>]", the commit's details the first time it appears ("author",
/// "author-time", "summary", …), then the line itself after a tab.
enum BlameParser {
    static func parse(_ text: String) -> [BlameLine] {
        var details: [String: (author: String, date: Date, summary: String)] = [:]
        var lines: [BlameLine] = []
        var oid = "", number = 0
        var author = "", date = Date(timeIntervalSince1970: 0), summary = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                let known = details[oid] ?? (author, date, summary)
                details[oid] = known
                lines.append(BlameLine(oid: oid, number: number, author: known.author, date: known.date,
                                       summary: known.summary, text: String(line.dropFirst())))
            } else if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time "), let seconds = TimeInterval(line.dropFirst("author-time ".count)) {
                date = Date(timeIntervalSince1970: seconds)
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst("summary ".count))
            } else {
                let fields = line.split(separator: " ")
                if fields.count >= 3, fields[0].count >= 40, fields[0].allSatisfy(\.isHexDigit), let final = Int(fields[2]) {
                    oid = String(fields[0])
                    number = final
                }
            }
        }
        return lines.sorted { $0.number < $1.number }
    }
}

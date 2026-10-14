import Foundation

/// Just enough markdown understanding to build the cosmos: wikilinks and tags.
enum MarkdownParser {

    /// `[[Target]]`, `[[Target|alias]]`, `[[Target#Heading]]`, `[[folder/Target.md]]` → "Target".
    /// Embeds (`![[image.png]]`) are skipped.
    static func links(in text: String) -> [String] {
        var result: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "[[") {
            let isEmbed = open.lowerBound > rest.startIndex && rest[rest.index(before: open.lowerBound)] == "!"
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            var target = String(after[..<close.lowerBound])
            rest = after[close.upperBound...]
            if isEmbed || target.contains("\n") { continue }
            if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
            if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
            if let slash = target.lastIndex(of: "/") { target = String(target[target.index(after: slash)...]) }
            if target.lowercased().hasSuffix(".md") { target.removeLast(3) }
            target = target.trimmingCharacters(in: .whitespaces)
            if !target.isEmpty { result.append(target) }
        }
        return result
    }

    private static let tagRegex = try! NSRegularExpression(pattern: "(?:^|\\s)#([\\p{L}\\p{N}_/-]*[\\p{L}_/-][\\p{L}\\p{N}_/-]*)")

    /// Inline `#tags` outside the frontmatter. Headings (`# Title`) are not tags because a space follows `#`.
    static func tags(in text: String) -> [String] {
        let body = stripFrontmatter(text)
        let ns = body as NSString
        let matches = tagRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        return matches.compactMap { m in
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            return seen.insert(tag).inserted ? tag : nil
        }
    }

    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }
}

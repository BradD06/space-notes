import Foundation

/// Just enough markdown understanding to build the cosmos: wikilinks and tags.
nonisolated enum MarkdownParser {

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
            target = Documents.strippingExtension(target)   // [[Book.pdf#page=3]], [[Report.docx]] link to the file
            target = target.trimmingCharacters(in: .whitespaces)
            if !target.isEmpty { result.append(target) }
        }
        return result
    }

    private static let tagRegex = try! NSRegularExpression(pattern: "(?:^|\\s)#([\\p{L}\\p{N}_/-]*[\\p{L}_/-][\\p{L}\\p{N}_/-]*)")

    /// The note's tags as Obsidian sees them: the `tags:` property first, then inline `#tags` in the text.
    /// Headings (`# Title`) are not tags because a space follows `#`.
    static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in propertyTags(in: text) where seen.insert(tag).inserted { result.append(tag) }
        let body = stripFrontmatter(text)
        let ns = body as NSString
        for m in tagRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// `tags:` (or `tag:`) in the frontmatter: a list, "[a, b]" or "a, b" / "a b"; a leading "#" is dropped.
    static func propertyTags(in text: String) -> [String] {
        guard let fm = Properties.frontmatter(in: text as NSString) else { return [] }
        var values: [String] = []
        if let props = Properties.parse(fm.yaml) {
            for p in props where ["tags", "tag"].contains(p.key.lowercased()) {
                switch p.value {
                case .list(let items): values += items
                case .text(let s): values += s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                case .bool: break
                }
            }
        } else {
            // YAML too fancy for the properties panel: still pick up a plain "tags:" list.
            var inTags = false
            for raw in fm.yaml.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let colon = line.firstIndex(of: ":"), raw.first.map({ !$0.isWhitespace }) ?? false {
                    let key = line[..<colon].lowercased()
                    inTags = key == "tags" || key == "tag"
                    let rest = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                    if inTags, !rest.isEmpty { values += rest.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) }
                } else if inTags, line.hasPrefix("- ") {
                    values.append(String(line.dropFirst(2)))
                }
            }
        }
        return values.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")).lowercased()
        }.filter { !$0.isEmpty }
    }

    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }
}

import Foundation

/// Files of the vault that are neither notes (Markdown) nor books (PDF): plain text and code, tables,
/// rich text, web pages, e-books and the rest. Each is a star too and opens in a tab like a note.
nonisolated enum Documents {

    enum Kind {
        /// Plain text, logs, data and source code: edited as text.
        case text
        /// CSV / TSV: a table, or its text.
        case table
        /// RTF, Word, OpenDocument: a page of formatted text.
        case rich
        /// HTML: the page as a browser shows it, or its source.
        case web
        /// An EPUB book, chapter by chapter.
        case epub
        /// Whatever the system can preview (Pages and the like).
        case preview
    }

    static let textExtensions: Set<String> = [
        "txt", "text", "log", "markdown", "mdown", "org", "rst", "adoc", "tex", "bib", "srt", "vtt",
        "json", "jsonl", "geojson", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "env",
        "xml", "svg", "plist", "opml", "csl",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "gradle", "go", "rs",
        "py", "rb", "php", "pl", "lua", "r", "dart", "scala", "hs", "ex", "exs", "clj", "zig", "nim",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "css", "scss", "sass", "less",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "sql", "graphql", "proto", "dockerfile", "make", "cmake"
    ]
    /// Text that reads as prose (shown in the text font, not monospaced).
    static let proseExtensions: Set<String> = ["txt", "text", "markdown", "mdown", "org", "rst", "adoc", "srt", "vtt"]
    static let tableExtensions: Set<String> = ["csv", "tsv"]
    static let richExtensions: Set<String> = ["rtf", "rtfd", "docx", "doc", "odt", "wordml"]
    static let webExtensions: Set<String> = ["html", "htm", "xhtml", "webarchive"]
    static let previewExtensions: Set<String> = ["pages"]
    /// Documents that are folders on disk (packages): the scanner takes them as one file.
    static let packageExtensions: Set<String> = ["rtfd", "pages"]

    static func kind(ofExtension raw: String) -> Kind? {
        let ext = raw.lowercased()
        if textExtensions.contains(ext) { return .text }
        if tableExtensions.contains(ext) { return .table }
        if richExtensions.contains(ext) { return .rich }
        if webExtensions.contains(ext) { return .web }
        if ext == "epub" { return .epub }
        if previewExtensions.contains(ext) { return .preview }
        return nil
    }

    static func kind(of id: String) -> Kind? { kind(ofExtension: (id as NSString).pathExtension) }
    static func isDocument(_ id: String) -> Bool { kind(of: id) != nil }
    /// A Markdown note (not a book, not a document).
    static func isNote(_ id: String) -> Bool { id.lowercased().hasSuffix(".md") }

    /// Every file the vault shows: notes, books and documents.
    static func isShown(extension raw: String) -> Bool {
        let ext = raw.lowercased()
        return ext == "md" || ext == "pdf" || kind(ofExtension: ext) != nil
    }

    /// The icon of a star in tabs and the explorer.
    static func icon(for id: String) -> String {
        if Books.isBook(id) { return "book.closed" }
        switch kind(of: id) {
        case .text?:
            let ext = (id as NSString).pathExtension.lowercased()
            return proseExtensions.contains(ext) || ext == "log" ? "doc.plaintext" : "chevron.left.forwardslash.chevron.right"
        case .table?: return "tablecells"
        case .rich?: return "doc.richtext"
        case .web?: return "globe"
        case .epub?: return "books.vertical"
        case .preview?: return "doc.viewfinder"
        case nil: return "doc.text"
        }
    }

    /// "Report.docx#x" → "Report", "Note.md" → "Note": a link's target without the file's extension.
    static func strippingExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, isShown(extension: ext) else { return name }
        return (name as NSString).deletingPathExtension
    }

    /// True when a link names a file that is not a note, e.g. [[Report.docx]] (so no note is created for it).
    static func namesFile(_ link: String) -> Bool {
        let ext = (link as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ext != "md" && isShown(extension: ext)
    }

    // MARK: Text

    /// A text file's contents and the encoding it is in (so it is saved back the same way).
    /// Nil for files that aren't text (a zero byte inside).
    static func readText(at url: URL) -> (text: String, encoding: String.Encoding)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty { return ("", .utf8) }
        let hasBOM16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if !hasBOM16, data.prefix(8192).contains(0) { return nil }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        if hasBOM16, let s = String(data: data, encoding: .utf16) { return (s, .utf16) }
        // Old Russian texts are often in Windows-1251; Latin-1 reads anything else.
        for encoding in [String.Encoding.windowsCP1251, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return (s, encoding) }
        }
        return nil
    }

    // MARK: Tables

    /// Rows of a CSV (or TSV) text, with quoted fields ("a, b", "say ""hi""") and line breaks inside quotes.
    static func rows(of text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

import Foundation
import Compression

/// An EPUB book unpacked into the app's caches: its title and chapters in reading order.
/// EPUB is a ZIP of XHTML pages, so the chapters open in a web view straight from the unpacked folder.
nonisolated struct EPUBBook: Sendable {
    struct Chapter: Sendable, Hashable {
        var title: String
        var url: URL
    }
    var title: String
    var chapters: [Chapter]
    /// The unpacked folder: web views get read access to all of it (pictures, styles).
    var folder: URL

    enum Failure: LocalizedError {
        case notZip, noContents
        var errorDescription: String? {
            switch self {
            case .notZip: "Файл не похож на EPUB."
            case .noContents: "В книге не нашлось глав."
            }
        }
    }

    /// Unpacks the book (once per version of the file) and reads its contents.
    static func open(_ url: URL) throws -> EPUBBook {
        let fm = FileManager.default
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        // A stable name for this file (Swift's hashValue changes between launches).
        let hash = url.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let key = "\(String(hash, radix: 36))-\(Int(modified.timeIntervalSince1970))"
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appending(path: "EPUB", directoryHint: .isDirectory).appending(path: key, directoryHint: .isDirectory)
        if !fm.fileExists(atPath: folder.appending(path: "META-INF/container.xml").path) {
            try? fm.removeItem(at: folder)
            try ZipArchive.unpack(Data(contentsOf: url, options: .mappedIfSafe), into: folder)
        }

        // META-INF/container.xml → the package (.opf) → manifest + spine (+ the NCX table of contents).
        let container = try Data(contentsOf: folder.appending(path: "META-INF/container.xml"))
        guard let opfPath = XMLScan(container).elements.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else {
            throw Failure.noContents
        }
        let opfURL = folder.appending(path: opfPath)
        let opf = XMLScan(try Data(contentsOf: opfURL))
        let base = opfURL.deletingLastPathComponent()
        var manifest: [String: (href: String, type: String)] = [:]
        var spine: [String] = []
        var ncxID: String?
        for e in opf.elements {
            switch e.name {
            case "item":
                if let id = e.attributes["id"], let href = e.attributes["href"] {
                    manifest[id] = (href.removingPercentEncoding ?? href, e.attributes["media-type"] ?? "")
                }
            case "itemref":
                if let id = e.attributes["idref"], e.attributes["linear"] != "no" { spine.append(id) }
            case "spine":
                ncxID = e.attributes["toc"]
            default: break
            }
        }

        // Chapter names from the NCX, keyed by file.
        var names: [String: String] = [:]
        if let ncx = ncxID.flatMap({ manifest[$0] }), let data = try? Data(contentsOf: base.appending(path: ncx.href)) {
            let ncxBase = base.appending(path: ncx.href).deletingLastPathComponent()
            var label: String?
            for e in XMLScan(data).elements {
                if e.name == "text", label == nil { label = e.text }
                if e.name == "content", let src = e.attributes["src"] {
                    let file = ncxBase.appending(path: (src.components(separatedBy: "#").first ?? src).removingPercentEncoding ?? src)
                        .standardizedFileURL.path
                    if names[file] == nil, let label { names[file] = label.trimmingCharacters(in: .whitespacesAndNewlines) }
                    label = nil
                }
                if e.name == "navPoint" { label = nil }
            }
        }

        var chapters: [Chapter] = []
        for id in spine {
            guard let item = manifest[id] else { continue }
            let file = base.appending(path: item.href).standardizedFileURL
            guard file.path.hasPrefix(folder.standardizedFileURL.path) else { continue }
            chapters.append(Chapter(title: names[file.path] ?? "Глава \(chapters.count + 1)", url: file))
        }
        guard !chapters.isEmpty else { throw Failure.noContents }
        let title = opf.elements.first { $0.name == "title" }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EPUBBook(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title, chapters: chapters, folder: folder)
    }
}

/// Element names (without namespace prefix), attributes and text of a small XML file, in document order.
nonisolated private final class XMLScan: NSObject, XMLParserDelegate {
    struct Element { var name: String; var attributes: [String: String]; var text: String }
    private(set) var elements: [Element] = []
    private var open: [Int] = []

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        open.append(elements.count)
        elements.append(Element(name: local, attributes: attributes, text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let i = open.last { elements[i].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = open.popLast()
    }
}

/// Just enough ZIP to unpack an EPUB: stored and deflated entries, read through the central directory.
nonisolated enum ZipArchive {

    static func unpack(_ data: Data, into folder: URL) throws {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < bytes.count ? Int(bytes[i]) | Int(bytes[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        // The end-of-central-directory record sits in the last 64 KB.
        var end = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if u32(i) == 0x0605_4b50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw EPUBBook.Failure.notZip }
        let count = u16(end + 10)
        var p = u32(end + 16)
        let fm = FileManager.default
        let root = folder.standardizedFileURL.path

        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { throw EPUBBook.Failure.notZip }
            let method = u16(p + 10)
            let compressed = u32(p + 20), size = u32(p + 24)
            let nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<min(bytes.count, p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extra + comment

            guard !name.hasSuffix("/") else { continue }
            let target = folder.appending(path: name).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { continue }      // no "../" escapes
            guard local + 30 <= bytes.count, u32(local) == 0x0403_4b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count else { continue }

            let body: Data
            switch method {
            case 0:
                body = Data(bytes[start..<(start + compressed)])
            case 8:
                guard size > 0 else { body = Data(); break }
                var out = [UInt8](repeating: 0, count: size)
                let written = bytes.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        compression_decode_buffer(dst.baseAddress!, size, src.baseAddress! + start, compressed, nil, COMPRESSION_ZLIB)
                    }
                }
                body = Data(out.prefix(written))
            default:
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: target)
        }
    }
}

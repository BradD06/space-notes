import Foundation

/// Walks a vault folder and turns every `.md` file into a `Note`.
/// Hidden folders (`.obsidian`, `.trash`, `.git`) are skipped.
enum VaultScanner {

    /// Notes plus the folders of the first two levels (so empty universes and constellations show up too).
    static func scan(root: URL) throws -> (notes: [Note], folders: [String]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return ([], [])
        }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var notes: [Note] = []
        var folderList: [String] = []

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))

            if name.hasPrefix(".") {
                // iCloud keeps not-yet-downloaded files as hidden ".Name.md.icloud" placeholders.
                if name.hasSuffix(".md.icloud") { try? fm.startDownloadingUbiquitousItem(at: url) }
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let fullPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath) else { continue }
            let relative = String(fullPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if values?.isDirectory == true {
                if relative.split(separator: "/").count <= 2 { folderList.append(relative) }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let folders = relative.split(separator: "/").dropLast().map(String.init)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

            notes.append(Note(
                id: relative,
                title: url.deletingPathExtension().lastPathComponent,
                universe: folders.first ?? "",
                constellation: folders.count > 1 ? folders[1] : "",
                links: MarkdownParser.links(in: text),
                tags: MarkdownParser.tags(in: text),
                created: values?.creationDate ?? .distantPast,
                modified: values?.contentModificationDate ?? .distantPast
            ))
        }
        return (notes, folderList)
    }
}

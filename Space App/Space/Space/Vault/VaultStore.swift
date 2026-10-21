import Foundation
import Observation

/// Owns the opened vault: the folder, the parsed cosmos, what is selected, and reading/writing notes.
@MainActor
@Observable
final class VaultStore {

    enum Selection: Hashable {
        case map
        case note(String)
        /// The vault's dashboard (its profile page).
        case dashboard
    }

    private(set) var rootURL: URL?
    private(set) var cosmos = Cosmos()
    /// Bumped every time `cosmos` changes, so views can recompute layouts cheaply.
    private(set) var generation = 0
    private(set) var isLoading = false
    var errorMessage: String?
    /// A book asked to open at a page (a link like [[Book.pdf#page=42]]): book id → page number (from 1).
    var bookPage: [String: Int] = [:]
    /// …and the words of the quote to find and light up on that page.
    var bookFind: [String: String] = [:]
    var selection: Selection? = .dashboard {
        didSet {
            // Back / forward history, like a browser.
            guard !navigating, let old = oldValue, old != selection else { return }
            backStack.append(old)
            if backStack.count > 50 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
    }
    private(set) var backStack: [Selection] = []
    private(set) var forwardStack: [Selection] = []
    private var navigating = false

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        navigating = true
        if let cur = selection { forwardStack.append(cur) }
        selection = prev
        navigating = false
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        navigating = true
        if let cur = selection { backStack.append(cur) }
        selection = next
        navigating = false
    }
    /// True when the app may read the vault but not write to it. The UI then asks the user for access.
    private(set) var needsWriteAccess = false

    private var isAccessing = false
    /// Sees changes other apps (Obsidian, Finder, iCloud) make to the vault while it is open.
    private var watcher: VaultWatcher?
    /// Notes Space itself just saved (id → when): the watcher's echo of these is not an outside change.
    private var ownWrites: [String: Date] = [:]
    /// The file behind each note (id → file identifier), to recognise a note renamed or moved outside Space.
    private var fileIDs: [String: UInt64] = [:]
    /// Notes renamed or moved outside Space, old id → new id: tabs and unsaved edits follow them.
    private var renamed: [String: String] = [:]
    /// Notes the last reread found under a new name (old id → new id); the workspace moves their tabs along.
    private(set) var lastMoves: [String: String] = [:]
    /// Each reread gets a number; a slower, older one doesn't overwrite a newer result.
    private var scanNumber = 0
    /// Parent folder picked when creating a vault; kept open so the new vault stays writable this session.
    private var parentAccess: URL?

    var vaultName: String { rootURL?.lastPathComponent ?? "Space" }

    // MARK: Opening

    func restore() async {
        guard rootURL == nil, let url = BookmarkStore.restore() else { return }
        await open(url, remember: false)
    }

    func open(_ url: URL, remember: Bool = true) async {
        stopWatching()
        stopAccessing()
        isAccessing = url.startAccessingSecurityScopedResource()
        rootURL = url
        fileIDs = [:]
        renamed = [:]
        UniverseColors.shared.load(vault: url.path)
        VaultProfile.shared.load(root: url)
        BookStats.shared.load(root: url)
        if remember {
            do { try BookmarkStore.save(url) } catch { errorMessage = "Не удалось запомнить папку: \(error.localizedDescription)" }
        }
        selection = .dashboard
        checkWritable()
        await reload()
        startWatching()
    }

    /// The user picked the folder again in the system dialog — this grants (and remembers) write access.
    func grantAccess(with url: URL) async {
        await open(url)
    }

    private func checkWritable() {
        guard let root = rootURL else { needsWriteAccess = false; return }
        needsWriteAccess = !FileManager.default.isWritableFile(atPath: root.path)
    }

    /// Runs a file operation; a "no permission" failure turns into a friendly error and the access prompt.
    private func writing<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch {
            if Self.isPermissionError(error) { needsWriteAccess = true; throw CreateError.noPermission }
            throw error
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    func close() {
        stopWatching()
        stopAccessing()
        if let p = parentAccess { p.stopAccessingSecurityScopedResource(); parentAccess = nil }
        BookmarkStore.forget()
        rootURL = nil
        VaultProfile.shared.load(root: nil)
        BookStats.shared.load(root: nil)
        setCosmos(Cosmos())
        selection = .map
    }

    func reload() async {
        guard let root = rootURL else { return }
        scanNumber += 1
        let number = scanNumber
        isLoading = true
        defer { if number == scanNumber { isLoading = false } }
        do {
            let (built, ids) = try await Task.detached(priority: .userInitiated) { () throws -> (Cosmos, [String: UInt64]) in
                let scanned = try VaultScanner.scan(root: root)
                var ids: [String: UInt64] = [:]
                for note in scanned.notes {
                    ids[note.id] = try? root.appending(path: note.id).resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
                }
                return (Cosmos(notes: scanned.notes, folders: scanned.folders), ids)
            }.value
            guard number == scanNumber, root == rootURL else { return }
            followMoves(newIDs: ids, in: built)
            setCosmos(built)
        } catch {
            errorMessage = "Не удалось прочитать хранилище: \(error.localizedDescription)"
        }
    }

    /// Notes that vanished from one path and whose file turned up at another were renamed or moved:
    /// remember it, so the open note, its tabs and its unsaved edits go along.
    private func followMoves(newIDs: [String: UInt64], in built: Cosmos) {
        var byFile: [UInt64: String] = [:]
        for (id, file) in newIDs where cosmos.notes[id] == nil { byFile[file] = id }
        var moves: [String: String] = [:]
        for (old, file) in fileIDs where newIDs[old] == nil {
            if let new = byFile[file] { moves[old] = new }
        }
        fileIDs = newIDs
        lastMoves = moves
        guard !moves.isEmpty else { return }
        for (old, new) in renamed { if let newer = moves[new] { renamed[old] = newer } }
        renamed.merge(moves) { _, new in new }
        if case .note(let id) = selection, let new = moves[id] {
            navigating = true
            selection = .note(new)
            navigating = false
        }
    }

    // MARK: Watching

    private func startWatching() {
        guard let root = rootURL else { return }
        let w = VaultWatcher(root: root) { [weak self] paths in self?.changedOutside(paths) }
        w.start()
        watcher = w
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// The watcher saw files change: reread the vault, then let open notes take the new text.
    private func changedOutside(_ paths: [String]) {
        guard let root = rootURL else { return }
        let rootPath = Self.canonical(root.path)
        let now = Date.now
        ownWrites = ownWrites.filter { now.timeIntervalSince($0.value) < 3 }
        let ignored = [".obsidian", ".git", ".trash"]       // other apps' settings, history and deleted files
        let changed = paths.compactMap { path -> String? in
            let full = Self.canonical(path)
            guard full.hasPrefix(rootPath) else { return nil }
            let rel = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if ownWrites[rel] != nil || ignored.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { return nil }
            return rel
        }
        guard !changed.isEmpty else { return }
        // Hidden files (Space's own profile, iCloud placeholders) don't change the cosmos; open pages still check them.
        let visible = changed.contains { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
        Task {
            if visible { await reload() }
            NotificationCenter.default.post(name: .spaceVaultChangedOutside, object: nil)
        }
    }

    /// Back in the app (iOS suspends file presenters in the background): pick up what changed meanwhile.
    func refreshFromDisk() async {
        guard rootURL != nil else { return }
        await reload()
        NotificationCenter.default.post(name: .spaceVaultChangedOutside, object: nil)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Notes

    func url(for id: String) -> URL? { rootURL?.appending(path: id) }

    func text(of id: String) -> String {
        guard let url = url(for: id) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func save(_ id: String, text: String) {
        // Renamed in another app while open: the edits go to the note's new place.
        let moved = renamed[id]
        let id = moved ?? id
        guard write(id, { try text.write(to: $0, atomically: true, encoding: .utf8) }) else { return }
        guard var note = cosmos.notes[id] else { return }
        note.links = MarkdownParser.links(in: text)
        note.tags = MarkdownParser.tags(in: text)
        note.modified = .now
        setCosmos(cosmos.updating(note))
        // The page now open under the new name read the file before these edits reached it.
        if moved != nil { NotificationCenter.default.post(name: .spaceVaultChangedOutside, object: nil) }
    }

    /// Saves a document of the vault (text, RTF…): `work` writes it to the URL it is given.
    func saveDocument(_ id: String, _ work: (URL) throws -> Void) {
        let id = renamed[id] ?? id
        guard write(id, work), var note = cosmos.notes[id] else { return }
        note.modified = .now
        setCosmos(cosmos.updating(note))
    }

    /// Writes a file of the vault in place, coordinated with iCloud and other apps. False (and the error shown) if it failed.
    private func write(_ id: String, _ work: (URL) throws -> Void) -> Bool {
        // A note that was just moved or deleted must not come back at its old place.
        guard let url = url(for: id), FileManager.default.fileExists(atPath: url.path) else { return false }
        ownWrites[id] = .now
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: watcher).coordinate(writingItemAt: url, options: [], error: &coordinatorError) { target in
            do { try work(target) } catch { writeError = error }
        }
        if let e = writeError ?? coordinatorError {
            if Self.isPermissionError(e) {
                needsWriteAccess = true
                errorMessage = "Нет доступа на запись в хранилище. Нажми «Дать доступ» вверху и выбери папку хранилища."
            } else {
                errorMessage = "Не удалось сохранить: \(e.localizedDescription)"
            }
            return false
        }
        return true
    }

    // MARK: Creating a vault

    /// Creates `parent/name`, optionally fills it with a tiny starter universe, and opens it.
    func createVault(named raw: String, in parent: URL, withStarter: Bool) async throws {
        let name = Self.clean(raw)
        guard !name.isEmpty else { throw CreateError.emptyName }
        if let old = parentAccess { old.stopAccessingSecurityScopedResource() }
        parentAccess = parent.startAccessingSecurityScopedResource() ? parent : nil

        let root = parent.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CreateError.exists }
        try writing { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

        if withStarter {
            let ideas = root.appending(path: "Моя первая вселенная", directoryHint: .isDirectory)
                .appending(path: "Идеи", directoryHint: .isDirectory)
            try writing { try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true) }
            let files: [(URL, String)] = [
                (root.appending(path: "Добро пожаловать.md"), """
                # Добро пожаловать в Space

                Каждая папка верхнего уровня — это **вселенная**, папка внутри неё — **созвездие**, а каждая заметка — **звезда**.
                Ссылка вида [[Первая звезда]] рисует между звёздами линию на карте.

                Создавай новые вселенные, созвездия и звёзды кнопками над боковой панелью.
                """),
                (ideas.appending(path: "Первая звезда.md"), """
                # Первая звезда

                Звёзды, связанные ссылками, выстраиваются вокруг друг друга на орбитах.
                Отсюда ведут линии к [[Вторая звезда]] и к [[Добро пожаловать]].
                """),
                (ideas.appending(path: "Вторая звезда.md"), """
                # Вторая звезда

                Нажми на меня на карте — камера перелетит сюда, а [[Первая звезда]] встанет на орбиту.
                """)
            ]
            for (url, text) in files {
                try writing { try text.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
        await open(root)
    }

    // MARK: Creating universes, constellations and stars

    enum CreateError: LocalizedError {
        case emptyName, exists, noVault, inboxHasNoConstellations, noPermission, intoItself
        var errorDescription: String? {
            switch self {
            case .emptyName: "Нужно название."
            case .exists: "Такое уже есть."
            case .noVault: "Хранилище не открыто."
            case .inboxHasNoConstellations: "Во «Входящих» нет созвездий — это просто корень хранилища."
            case .noPermission: "У Space нет доступа на запись в эту папку. Нажми «Дать доступ» и выбери папку хранилища."
            case .intoItself: "Папку нельзя перенести в саму себя."
            }
        }
    }

    /// Folder name inside the vault for a universe ("" for Входящие = the vault root).
    func folderName(ofUniverse id: String) -> String {
        guard let name = cosmos.universe(id)?.name, name != Cosmos.inboxName else { return "" }
        return name
    }

    /// A universe is a top-level folder.
    func createUniverse(named raw: String) async throws {
        guard let root = rootURL else { throw CreateError.noVault }
        let name = Self.clean(raw)
        guard !name.isEmpty else { throw CreateError.emptyName }
        let url = root.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CreateError.exists }
        try writing { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        await reload()
    }

    /// A constellation is a folder inside a universe folder.
    func createConstellation(named raw: String, inUniverse universeID: String) async throws {
        guard let root = rootURL else { throw CreateError.noVault }
        let name = Self.clean(raw)
        guard !name.isEmpty else { throw CreateError.emptyName }
        let universe = folderName(ofUniverse: universeID)
        guard !universe.isEmpty else { throw CreateError.inboxHasNoConstellations }
        let url = root.appending(path: universe, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CreateError.exists }
        try writing { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        await reload()
    }

    /// A star is a markdown file. Returns its id so the caller can open it.
    @discardableResult
    func createStar(titled raw: String, inUniverse universeID: String, constellation: String) async throws -> String {
        guard let root = rootURL else { throw CreateError.noVault }
        let title = Self.clean(raw)
        guard !title.isEmpty else { throw CreateError.emptyName }
        var folder = ""
        let universe = folderName(ofUniverse: universeID)
        if !universe.isEmpty {
            folder = universe
            if !constellation.isEmpty && constellation != Cosmos.looseName { folder += "/" + Self.clean(constellation) }
        }
        let dir = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
        try writing { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        var fileName = title + ".md", n = 2
        while FileManager.default.fileExists(atPath: dir.appending(path: fileName).path) {
            fileName = "\(title) \(n).md"; n += 1
        }
        let target = dir.appending(path: fileName)
        try writing { try "# \(title)\n\n".write(to: target, atomically: true, encoding: .utf8) }
        await reload()
        let id = folder.isEmpty ? fileName : folder + "/" + fileName
        selection = .note(id)
        return id
    }

    /// A new note with this Markdown in a folder of the vault ("" = the root). Doesn't open it: returns its id.
    func createNote(titled raw: String, inFolder folder: String, text: String) throws -> String {
        guard let root = rootURL else { throw CreateError.noVault }
        let title = Self.clean(raw)
        guard !title.isEmpty else { throw CreateError.emptyName }
        let dir = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
        var fileName = title + ".md", n = 2
        while FileManager.default.fileExists(atPath: dir.appending(path: fileName).path) {
            fileName = "\(title) \(n).md"; n += 1
        }
        try writing {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appending(path: fileName), atomically: true, encoding: .utf8)
        }
        return folder.isEmpty ? fileName : folder + "/" + fileName
    }

    // MARK: Moving

    /// Moves a note, book or folder into another folder of the vault ("" = the root). Returns its new path,
    /// or nil if it already is there. The caller rereads the vault (after moving open tabs along).
    func move(_ relative: String, toFolder folder: String) throws -> String? {
        guard let root = rootURL else { throw CreateError.noVault }
        let rel = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let dest = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty else { throw CreateError.noVault }
        guard (rel as NSString).deletingLastPathComponent != dest else { return nil }
        guard dest != rel, !dest.hasPrefix(rel + "/") else { throw CreateError.intoItself }
        let fm = FileManager.default
        let source = root.appending(path: rel)
        let dir = dest.isEmpty ? root : root.appending(path: dest, directoryHint: .isDirectory)
        let name = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
        var target = dir.appending(path: source.lastPathComponent), n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appending(path: ext.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(ext)")
            n += 1
        }
        try writing {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
        }
        let newPath = dest.isEmpty ? target.lastPathComponent : dest + "/" + target.lastPathComponent
        // The book's remembered page goes along.
        let d = UserDefaults.standard
        if d.object(forKey: "space.book.page." + rel) != nil {
            d.set(d.integer(forKey: "space.book.page." + rel), forKey: "space.book.page." + newPath)
        }
        BookStats.shared.rename(rel, to: newPath)
        return newPath
    }

    // MARK: Deleting

    /// Path of a constellation folder inside the vault ("" if it has none, e.g. "Свободные звёзды").
    func folderPath(ofConstellation name: String, inUniverse universeID: String) -> String {
        let universe = folderName(ofUniverse: universeID)
        guard !universe.isEmpty, !name.isEmpty, name != Cosmos.looseName else { return "" }
        return universe + "/" + name
    }

    /// Moves a folder (a universe or a constellation, with everything in it) or a note to the Trash.
    /// Where the system keeps no Trash for it, it goes into the vault's own ".trash" folder, as in Obsidian.
    /// Nothing is erased for good.
    func trash(_ relative: String) async throws {
        guard let root = rootURL else { throw CreateError.noVault }
        let rel = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty, !rel.hasPrefix(".") else { throw CreateError.noVault }
        let url = root.appending(path: rel)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try writing {
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    let bin = root.appending(path: ".trash", directoryHint: .isDirectory)
                    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
                    let name = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                    var target = bin.appending(path: url.lastPathComponent), n = 2
                    while fm.fileExists(atPath: target.path) {
                        target = bin.appending(path: ext.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(ext)")
                        n += 1
                    }
                    try fm.moveItem(at: url, to: target)
                }
            }
        }
        if case .note(let id) = selection, id == rel || id.hasPrefix(rel + "/") { selection = .map }
        await reload()
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] { t = t.replacingOccurrences(of: bad, with: "-") }
        while t.hasPrefix(".") { t.removeFirst() }
        return t
    }

    // MARK: Private

    private func setCosmos(_ new: Cosmos) {
        cosmos = new
        generation += 1
    }

    private func stopAccessing() {
        if isAccessing, let url = rootURL { url.stopAccessingSecurityScopedResource() }
        isAccessing = false
    }
}

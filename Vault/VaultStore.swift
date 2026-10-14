import Foundation
import Observation

/// Owns the opened vault: the folder, the parsed cosmos, what is selected, and reading/writing notes.
@MainActor
@Observable
final class VaultStore {

    enum Selection: Hashable {
        case map
        case note(String)
    }

    private(set) var rootURL: URL?
    private(set) var cosmos = Cosmos()
    /// Bumped every time `cosmos` changes, so views can recompute layouts cheaply.
    private(set) var generation = 0
    private(set) var isLoading = false
    var errorMessage: String?
    var selection: Selection? = .map
    /// True when the app may read the vault but not write to it. The UI then asks the user for access.
    private(set) var needsWriteAccess = false

    private var isAccessing = false
    /// Parent folder picked when creating a vault; kept open so the new vault stays writable this session.
    private var parentAccess: URL?

    var vaultName: String { rootURL?.lastPathComponent ?? "Space" }

    // MARK: Opening

    func restore() async {
        guard rootURL == nil, let url = BookmarkStore.restore() else { return }
        await open(url, remember: false)
    }

    func open(_ url: URL, remember: Bool = true) async {
        stopAccessing()
        isAccessing = url.startAccessingSecurityScopedResource()
        rootURL = url
        if remember {
            do { try BookmarkStore.save(url) } catch { errorMessage = "Не удалось запомнить папку: \(error.localizedDescription)" }
        }
        selection = .map
        checkWritable()
        await reload()
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
        stopAccessing()
        if let p = parentAccess { p.stopAccessingSecurityScopedResource(); parentAccess = nil }
        BookmarkStore.forget()
        rootURL = nil
        setCosmos(Cosmos())
        selection = .map
    }

    func reload() async {
        guard let root = rootURL else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let built = try await Task.detached(priority: .userInitiated) { () throws -> Cosmos in
                let scanned = try VaultScanner.scan(root: root)
                return Cosmos(notes: scanned.notes, folders: scanned.folders)
            }.value
            setCosmos(built)
        } catch {
            errorMessage = "Не удалось прочитать хранилище: \(error.localizedDescription)"
        }
    }

    // MARK: Notes

    func url(for id: String) -> URL? { rootURL?.appending(path: id) }

    func text(of id: String) -> String {
        guard let url = url(for: id) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func save(_ id: String, text: String) {
        guard let url = url(for: id) else { return }
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { target in
            do { try text.write(to: target, atomically: true, encoding: .utf8) } catch { writeError = error }
        }
        if let e = writeError ?? coordinatorError {
            if Self.isPermissionError(e) {
                needsWriteAccess = true
                errorMessage = "Нет доступа на запись в хранилище. Нажми «Дать доступ» вверху и выбери папку хранилища."
            } else {
                errorMessage = "Не удалось сохранить: \(e.localizedDescription)"
            }
            return
        }
        guard var note = cosmos.notes[id] else { return }
        note.links = MarkdownParser.links(in: text)
        note.tags = MarkdownParser.tags(in: text)
        note.modified = .now
        setCosmos(cosmos.updating(note))
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
        case emptyName, exists, noVault, inboxHasNoConstellations, noPermission
        var errorDescription: String? {
            switch self {
            case .emptyName: "Нужно название."
            case .exists: "Такое уже есть."
            case .noVault: "Хранилище не открыто."
            case .inboxHasNoConstellations: "Во «Входящих» нет созвездий — это просто корень хранилища."
            case .noPermission: "У Space нет доступа на запись в эту папку. Нажми «Дать доступ» и выбери папку хранилища."
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

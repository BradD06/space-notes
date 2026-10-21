import Foundation

/// Remembers the vault folder the user picked, so the app can reopen it after a relaunch.
/// Sandboxed apps only get access to folders the user chose, and keep it through a security-scoped bookmark.
enum BookmarkStore {
    private static let key = "space.vaultBookmark"

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: createOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            try? save(url)
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

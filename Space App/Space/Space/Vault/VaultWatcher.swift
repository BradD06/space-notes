import Foundation
#if os(macOS)
import CoreServices
#endif

extension Notification.Name {
    /// Files of the vault changed outside Space (Obsidian, Finder, iCloud, Files) and the vault was reread.
    static let spaceVaultChangedOutside = Notification.Name("space.vaultChangedOutside")
}

/// Watches the vault folder for changes made by other apps and reports the paths that changed.
/// On the Mac FSEvents sees every write, coordinated or not (Obsidian doesn't coordinate). On both systems
/// the folder is also a file presenter, so coordinated writes and moves (iCloud sync, the Files app) arrive too.
/// Bursts of changes are gathered and delivered together on the main actor.
nonisolated final class VaultWatcher: NSObject, NSFilePresenter, @unchecked Sendable {

    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    private let onChange: @MainActor @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "space.vaultWatcher")
    private var pending: Set<String> = []          // touched only on `queue`
    private var flushScheduled = false
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif

    /// `onChange` gets full file paths (a folder path when a whole folder must be rescanned).
    init(root: URL, onChange: @escaping @MainActor @Sendable ([String]) -> Void) {
        presentedItemURL = root
        self.onChange = onChange
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.underlyingQueue = queue
    }

    func start() {
        NSFileCoordinator.addFilePresenter(self)
        #if os(macOS)
        guard let root = presentedItemURL else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.collect(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        #endif
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        #if os(macOS)
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        #endif
    }

    // MARK: NSFilePresenter

    func presentedItemDidChange() { collect(presentedItemURL.map { [$0.path] } ?? []) }
    func presentedSubitemDidChange(at url: URL) { collect([url.path]) }
    func presentedSubitemDidAppear(at url: URL) { collect([url.path]) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { collect([oldURL.path, newURL.path]) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        collect([url.path])
        completionHandler(nil)
    }

    // MARK: Gathering

    private func collect(_ paths: [String]) {
        queue.async { [self] in
            pending.formUnion(paths)
            guard !flushScheduled else { return }
            flushScheduled = true
            // Saving a file is often several events (a temporary file, a rename): wait for the burst to end.
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in
                let batch = Array(pending)
                pending.removeAll()
                flushScheduled = false
                guard !batch.isEmpty else { return }
                let onChange = self.onChange
                Task { @MainActor in onChange(batch) }
            }
        }
    }
}

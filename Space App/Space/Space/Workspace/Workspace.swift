import SwiftUI
import Observation
import UniformTypeIdentifiers

/// The pane a view lives in, so it can make that pane the focused one before it opens something.
extension EnvironmentValues {
    @Entry var paneID: UUID? = nil
}

/// What a tab shows.
enum WorkTab: Hashable, Codable {
    case map
    case note(String)
    case dashboard
    /// A widget out of its note (see Widgets.swift): "note path#k".
    case widget(String)

    var selection: VaultStore.Selection {
        switch self {
        case .map: .map
        case .note(let id): .note(id)
        case .dashboard: .dashboard
        case .widget(let t): .widget(t)
        }
    }

    init?(_ s: VaultStore.Selection?) {
        switch s {
        case .map: self = .map
        case .note(let id): self = .note(id)
        case .dashboard: self = .dashboard
        case .widget(let t): self = .widget(t)
        default: return nil
        }
    }

    /// Text form used for drag and drop and for saving.
    var token: String {
        switch self {
        case .map: "map"
        case .note(let id): "note:" + id
        case .dashboard: "dashboard"
        case .widget(let t): "widget:" + t
        }
    }

    init?(token: String) {
        if token == "map" { self = .map }
        else if token == "dashboard" { self = .dashboard }
        else if token.hasPrefix("note:") { self = .note(String(token.dropFirst(5))) }
        else if token.hasPrefix("widget:") { self = .widget(String(token.dropFirst(7))) }
        else { return nil }
    }
}

/// A node of the layout tree: either a pane with tabs (a leaf) or a split of child nodes.
@MainActor
@Observable
final class PaneNode: Identifiable {
    let id = UUID()
    /// nil for a pane; .horizontal = children side by side, .vertical = children stacked.
    var axis: Axis?
    var children: [PaneNode] = []
    /// Share of the space each child gets (sums to 1).
    var fractions: [CGFloat] = []
    var tabs: [WorkTab] = []
    var active = 0
    @ObservationIgnored weak var parent: PaneNode?

    init(tabs: [WorkTab] = [.map]) { self.tabs = tabs }

    init(axis: Axis, children: [PaneNode], fractions: [CGFloat]) {
        self.axis = axis
        self.children = children
        self.fractions = fractions
        for c in children { c.parent = self }
    }

    var isPane: Bool { axis == nil }
    var activeTab: WorkTab? { tabs.indices.contains(active) ? tabs[active] : nil }
}

/// Where a dragged tab lands inside a pane.
enum DropZone: Equatable {
    case left, right, top, bottom, center

    static func at(_ p: CGPoint, in size: CGSize) -> DropZone {
        let x = p.x / max(size.width, 1), y = p.y / max(size.height, 1)
        // The closest edge wins if it is near enough; otherwise the middle.
        let edges: [(DropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let near = edges.min { $0.1 < $1.1 }!
        return near.1 < 0.25 ? near.0 : .center
    }
}

/// The window's layout of panes and tabs, like Obsidian's workspace. Saved between launches.
@MainActor
@Observable
final class Workspace {
    private(set) var root: PaneNode
    private(set) var focusedID: UUID
    private let saveKey = "space.workspace"

    init() {
        let pane = PaneNode(tabs: [.dashboard])
        root = pane
        focusedID = pane.id
        if let restored = Self.load(key: saveKey) {
            root = restored
            focusedID = Self.firstPane(in: restored)?.id ?? restored.id
        }
        startOnDashboard()
    }

    /// The app always opens on the dashboard: its tab if one is open anywhere, otherwise a new first tab
    /// in the first pane. The other tabs from last time stay where they were.
    private func startOnDashboard() {
        guard !reveal(.dashboard), let pane = Self.firstPane(in: root) else { return }
        pane.tabs.insert(.dashboard, at: 0)
        pane.active = 0
        focusedID = pane.id
        save()
    }

    var focused: PaneNode? { Self.find(focusedID, in: root) }
    /// How many panes are open (the focused one is only outlined when there's more than one).
    var paneCount: Int { Self.count(root) }
    private static func count(_ n: PaneNode) -> Int { n.isPane ? 1 : n.children.reduce(0) { $0 + count($1) } }

    // MARK: Showing things

    /// Something was picked elsewhere (sidebar, map, links): show it in the focused pane —
    /// switch to its tab if it is already open there, otherwise replace the current tab (like Obsidian).
    func show(_ selection: VaultStore.Selection?) {
        guard let tab = WorkTab(selection), let pane = focused ?? Self.firstPane(in: root) else { return }
        if pane.activeTab == tab { return }
        if let i = pane.tabs.firstIndex(of: tab) { pane.active = i }
        else if pane.tabs.isEmpty { pane.tabs = [tab]; pane.active = 0 }
        else { pane.tabs[pane.active] = tab }
        save()
    }

    /// If the tab is open in some pane, makes it that pane's active tab and focuses the pane.
    @discardableResult
    func reveal(_ tab: WorkTab) -> Bool {
        var found: (PaneNode, Int)?
        func walk(_ n: PaneNode) {
            guard found == nil else { return }
            if n.isPane { if let i = n.tabs.firstIndex(of: tab) { found = (n, i) } } else { n.children.forEach(walk) }
        }
        walk(root)
        guard let hit = found else { return false }
        let pane = hit.0
        pane.active = hit.1
        focusedID = pane.id
        save()
        return true
    }

    /// The pane showing a note (not a book) other than `paneID`, for opening a new note next to a book.
    func notePane(besides paneID: UUID?) -> PaneNode? {
        var panes: [PaneNode] = []
        func walk(_ n: PaneNode) { if n.isPane { panes.append(n) } else { n.children.forEach(walk) } }
        walk(root)
        return panes.first { p in
            guard p.id != paneID, case .note(let id)? = p.activeTab else { return false }
            return Documents.isNote(id)
        }
    }

    func openInNewTab(_ tab: WorkTab) {
        guard let pane = focused ?? Self.firstPane(in: root) else { return }
        pane.tabs.insert(tab, at: min(pane.active + 1, pane.tabs.count))
        pane.active = min(pane.active + 1, pane.tabs.count - 1)
        save()
    }

    func openToTheSide(_ tab: WorkTab) {
        guard let pane = focused ?? Self.firstPane(in: root) else { return }
        let new = PaneNode(tabs: [tab])
        split(pane, with: new, zone: .right)
        focusedID = new.id
        save()
    }

    func focus(_ pane: PaneNode) { if focusedID != pane.id { focusedID = pane.id } }

    func focus(id: UUID?) {
        if let id, focusedID != id, Self.find(id, in: root) != nil { focusedID = id }
    }

    func activate(_ pane: PaneNode, _ index: Int) {
        pane.active = index
        focus(pane)
        save()
    }

    func close(_ pane: PaneNode, _ index: Int) {
        guard pane.tabs.indices.contains(index) else { return }
        pane.tabs.remove(at: index)
        if pane.tabs.isEmpty {
            if pane === root { pane.tabs = [.map]; pane.active = 0 }
            else { remove(pane) }
        } else {
            pane.active = min(pane.active, pane.tabs.count - 1)
        }
        save()
    }

    func addTab(to pane: PaneNode) {
        pane.tabs.append(.map)
        pane.active = pane.tabs.count - 1
        focus(pane)
        save()
    }

    // MARK: Dragging (our own, inside the window)

    struct DropTarget: Equatable {
        let pane: UUID
        let zone: DropZone
        /// A place in that pane's tab bar; nil when dropped onto the pane's content.
        let index: Int?
    }

    struct TabDrag {
        let payload: String
        let title: String
        let icon: String
        var location: CGPoint
        var target: DropTarget?
        /// Over a folder in the sidebar: the file moves into it (vault path, "" is the vault's root).
        var folder: String?
    }

    /// The tab (or note from the sidebar) being dragged right now.
    private(set) var drag: TabDrag?
    /// Where panes, tab bars and tabs are in the window — reported by the views, read during a drag.
    @ObservationIgnored var paneFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var barFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var chipFrames: [UUID: [Int: CGRect]] = [:]
    /// Folder rows of the sidebar (vault path → frame in the window): drop targets for moving files.
    @ObservationIgnored var folderFrames: [String: CGRect] = [:]
    /// Moves a dragged note ("note:…") or folder ("folder:…") into a folder; set by the sidebar.
    @ObservationIgnored var onMoveToFolder: ((_ payload: String, _ folder: String) -> Void)?

    func beginDrag(_ payload: String, title: String, icon: String, at p: CGPoint) {
        drag = TabDrag(payload: payload, title: title, icon: icon, location: p)
        moveDrag(to: p)
    }

    func moveDrag(to p: CGPoint) {
        guard let d = drag else { return }
        drag?.location = p
        let folder = folderAt(p, payload: d.payload)
        if drag?.folder != folder { drag?.folder = folder }
        // Folders only go into folders; notes go into folders or panes.
        let t = folder == nil && !d.payload.hasPrefix("folder:") ? target(at: p) : nil
        if drag?.target != t { drag?.target = t }
    }

    /// The drag ended somewhere that handled it itself (a widget reordered on the dashboard).
    func cancelDrag() { drag = nil }

    func endDrag() {
        defer { drag = nil }
        guard let d = drag else { return }
        if let folder = d.folder {
            onMoveToFolder?(d.payload, folder)
            return
        }
        guard let t = d.target, let pane = Self.find(t.pane, in: root) else { return }
        drop(d.payload, on: pane, zone: t.zone, at: t.index)
    }

    /// The folder row under the pointer, if the dragged thing can go there.
    private func folderAt(_ p: CGPoint, payload: String) -> String? {
        let item: String
        if payload.hasPrefix("note:") { item = String(payload.dropFirst(5)) }
        else if payload.hasPrefix("folder:") { item = String(payload.dropFirst(7)) }
        else { return nil }                                   // tabs from the tab bar stay tabs
        guard let hit = folderFrames.first(where: { $0.value.contains(p) }) else { return nil }
        let path = hit.key
        if path == item || path.hasPrefix(item + "/") { return nil }       // not into itself
        if (item as NSString).deletingLastPathComponent == path { return nil }   // already there
        return path
    }

    /// A file or folder moved: tabs showing it (or anything inside it) follow it.
    func retarget(old: String, new: String) {
        func walk(_ n: PaneNode) {
            if n.isPane {
                n.tabs = n.tabs.map { tab in
                    guard case .note(let id) = tab else { return tab }
                    if id == old { return .note(new) }
                    if id.hasPrefix(old + "/") { return .note(new + id.dropFirst(old.count)) }
                    return tab
                }
            } else { n.children.forEach(walk) }
        }
        walk(root)
        save()
    }

    private func target(at p: CGPoint) -> DropTarget? {
        for (id, f) in barFrames where f.contains(p) {
            let chips = (chipFrames[id] ?? [:]).sorted { $0.key < $1.key }
            let index = chips.first(where: { p.x < $0.value.midX })?.key ?? chips.count
            return DropTarget(pane: id, zone: .center, index: index)
        }
        for (id, f) in paneFrames where f.contains(p) {
            return DropTarget(pane: id, zone: DropZone.at(CGPoint(x: p.x - f.minX, y: p.y - f.minY), in: f.size), index: nil)
        }
        return nil
    }

    // MARK: Drag and drop

    /// A drag payload: "tab|<paneID>|<index>" for a tab, or a plain tab token for a note from the sidebar.
    static func payload(pane: PaneNode, index: Int) -> String { "tab|\(pane.id.uuidString)|\(index)" }

    /// Drop a tab or a note onto a pane: into it (centre / tab bar) or as a new pane on one of its sides.
    /// `index`: a place in the target's tab bar (dropping between tabs); nil means "at the end".
    func drop(_ payload: String, on target: PaneNode, zone: DropZone, at index: Int? = nil) {
        var tab: WorkTab?
        var source: (PaneNode, Int)?
        let parts = payload.split(separator: "|", maxSplits: 2).map(String.init)
        if parts.count == 3, parts[0] == "tab", let pid = UUID(uuidString: parts[1]), let i = Int(parts[2]),
           let pane = Self.find(pid, in: root), pane.tabs.indices.contains(i) {
            tab = pane.tabs[i]
            source = (pane, i)
        } else {
            tab = WorkTab(token: payload)
        }
        guard let tab else { return }

        var insertAt = index
        if let src = source {
            let pane = src.0, i = src.1
            if pane === target {
                // Into its own pane: only a reorder makes sense; its only tab can't go to its own side.
                if zone == .center && index == nil { return }
                if zone != .center && pane.tabs.count == 1 { return }
                if zone == .center, let j = index, j == i || j == i + 1 { return }   // dropped where it already is
            }
            pane.tabs.remove(at: i)
            if pane === target, let j = insertAt, j > i { insertAt = j - 1 }
            pane.active = min(pane.active, max(pane.tabs.count - 1, 0))
            if pane.tabs.isEmpty, pane !== target { remove(pane) }
        }

        if zone == .center {
            let at = min(max(insertAt ?? target.tabs.count, 0), target.tabs.count)
            target.tabs.insert(tab, at: at)
            target.active = at
            focusedID = target.id
        } else {
            let new = PaneNode(tabs: [tab])
            split(target, with: new, zone: zone)
            focusedID = new.id
        }
        save()
    }

    // MARK: Tree surgery

    private func split(_ target: PaneNode, with new: PaneNode, zone: DropZone) {
        let axis: Axis = (zone == .left || zone == .right) ? .horizontal : .vertical
        let after = zone == .right || zone == .bottom
        if let parent = target.parent, parent.axis == axis, let i = parent.children.firstIndex(where: { $0 === target }) {
            // Same direction as the parent: just add a sibling and share the target's space.
            let half = parent.fractions[i] / 2
            parent.fractions[i] = half
            parent.children.insert(new, at: after ? i + 1 : i)
            parent.fractions.insert(half, at: after ? i + 1 : i)
            new.parent = parent
            return
        }
        // Otherwise the target becomes a split of itself and the new pane.
        let parent = target.parent
        let index = parent?.children.firstIndex(where: { $0 === target })
        let split = PaneNode(axis: axis, children: after ? [target, new] : [new, target], fractions: [0.5, 0.5])
        if let parent, let index {
            parent.children[index] = split
            split.parent = parent
        } else {
            root = split
            split.parent = nil
        }
    }

    private func remove(_ pane: PaneNode) {
        guard let parent = pane.parent, let i = parent.children.firstIndex(where: { $0 === pane }) else { return }
        let freed = parent.fractions[i]
        parent.children.remove(at: i)
        parent.fractions.remove(at: i)
        // Give the freed space to the neighbours.
        let total = parent.fractions.reduce(0, +)
        if total > 0 { parent.fractions = parent.fractions.map { $0 + freed * $0 / total } }
        if focusedID == pane.id { focusedID = Self.firstPane(in: parent)?.id ?? root.id }
        if parent.children.count == 1 {
            // A split with one child is just that child.
            let only = parent.children[0]
            if let grand = parent.parent, let j = grand.children.firstIndex(where: { $0 === parent }) {
                grand.children[j] = only
                only.parent = grand
                // Same direction as the grandparent: flatten.
                if only.axis == grand.axis, let axis = only.axis {
                    _ = axis
                    let share = grand.fractions[j]
                    grand.children.replaceSubrange(j...j, with: only.children)
                    grand.fractions.replaceSubrange(j...j, with: only.fractions.map { $0 * share })
                    for c in only.children { c.parent = grand }
                }
            } else {
                root = only
                only.parent = nil
            }
        }
    }

    /// Divider dragged between children `i` and `i + 1`.
    func resize(_ node: PaneNode, at i: Int, by delta: CGFloat) {
        guard node.fractions.indices.contains(i + 1) else { return }
        let a = node.fractions[i] + delta, b = node.fractions[i + 1] - delta
        guard a > 0.12, b > 0.12 else { return }
        node.fractions[i] = a
        node.fractions[i + 1] = b
    }

    func endResize() { save() }

    // MARK: Lookup

    static func find(_ id: UUID, in node: PaneNode) -> PaneNode? {
        if node.id == id { return node }
        for c in node.children { if let f = find(id, in: c) { return f } }
        return nil
    }

    /// The note open in another pane next to `paneID` (where a book's quotes go), if any.
    func noteNextTo(_ paneID: UUID?) -> String? {
        var panes: [PaneNode] = []
        func walk(_ n: PaneNode) { if n.isPane { panes.append(n) } else { n.children.forEach(walk) } }
        walk(root)
        // The focused pane first (when it isn't the book's own), then the others.
        if let i = panes.firstIndex(where: { $0.id == focusedID }) { panes.insert(panes.remove(at: i), at: 0) }
        for p in panes where p.id != paneID {
            if case .note(let id)? = p.activeTab, Documents.isNote(id) { return id }
        }
        return nil
    }

    static func firstPane(in node: PaneNode) -> PaneNode? {
        node.isPane ? node : node.children.lazy.compactMap { firstPane(in: $0) }.first
    }

    /// Drops tabs of notes that no longer exist (renamed or deleted files).
    func prune(existing: (String) -> Bool) {
        func walk(_ n: PaneNode) {
            if n.isPane {
                n.tabs.removeAll {
                    if case .note(let id) = $0 { return !existing(id) }
                    if case .widget(let t) = $0 { return !(WidgetRef(token: t).map { existing($0.note) } ?? false) }
                    return false
                }
                if n.tabs.isEmpty { n.tabs = [.map] }
                n.active = min(n.active, n.tabs.count - 1)
            }
            n.children.forEach(walk)
        }
        walk(root)
    }

    // MARK: Saving

    private struct Saved: Codable {
        var axis: String?
        var children: [Saved]
        var fractions: [Double]
        var tabs: [String]
        var active: Int
    }

    private func encode(_ n: PaneNode) -> Saved {
        Saved(axis: n.axis.map { $0 == .horizontal ? "h" : "v" }, children: n.children.map(encode),
              fractions: n.fractions.map(Double.init), tabs: n.tabs.map(\.token), active: n.active)
    }

    private static func decode(_ s: Saved) -> PaneNode {
        if let a = s.axis, !s.children.isEmpty {
            return PaneNode(axis: a == "h" ? .horizontal : .vertical, children: s.children.map(decode),
                            fractions: s.fractions.map { CGFloat($0) })
        }
        let p = PaneNode(tabs: s.tabs.compactMap(WorkTab.init(token:)))
        if p.tabs.isEmpty { p.tabs = [.map] }
        p.active = min(max(s.active, 0), p.tabs.count - 1)
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(encode(root)) { UserDefaults.standard.set(data, forKey: saveKey) }
    }

    private static func load(key: String) -> PaneNode? {
        guard let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return decode(s)
    }
}

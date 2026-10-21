import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// ```dataviewjs blocks: the block's JavaScript runs in a web view with DataviewShim.js standing in for
/// Obsidian and the Dataview plugin (dv.pages, dv.view, app.vault, ```tasks queries …). The vault's pages
/// go in as JSON; reading and writing files, opening notes and network requests come back through `space`.
nonisolated enum DataviewJS {
    static let language = "dataviewjs"

    /// The block's code without its fences.
    static func code(of block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeFirst() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func isJS(_ block: String) -> Bool {
        let first = block.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces).lowercased()
        return first.hasPrefix("```" + language) || first.hasPrefix("~~~" + language)
    }

    /// A value as JSON for the shim: dates and links marked so they come back as DateTime and Link.
    static func json(_ v: DVValue) -> Any {
        switch v {
        case .null, .lambda: NSNull()
        case .bool(let b): b
        case .number(let n): n.isFinite ? n : NSNull()
        case .string(let s): s
        case .date(let d): ["$d": (d.timeIntervalSince1970 * 1000).rounded()]
        case .duration(let d): ["$dur": Double(d.months) * 2_629_800 + d.seconds]
        case .link(let l): l.display.map { ["$l": l.target, "d": $0] } ?? ["$l": l.target]
        case .list(let items): items.map(json)
        case .object(let o): o.mapValues(json)
        }
    }

    static func pagesJSON(_ index: DVIndex) -> [Any] {
        index.pages.values.sorted { $0.id < $1.id }.map { json(.object($0.fields)) }
    }

    /// Every file and folder of the vault (hidden ones skipped), for app.vault.getAbstractFileByPath.
    static func listing(root: URL) -> (files: [String], folders: [String]) {
        var files: [String] = [], folders: [String] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        for case let url as URL in e {
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(rel) } else { files.append(rel) }
        }
        return (files, folders)
    }

    /// The vault's own CSS snippets (only the ones switched on in Obsidian), so widgets look as they do there.
    static func snippetsCSS(root: URL) -> String {
        let obsidian = root.appending(path: ".obsidian")
        guard let data = try? Data(contentsOf: obsidian.appending(path: "appearance.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["enabledCssSnippets"] as? [String] else { return "" }
        return enabled.compactMap { try? String(contentsOf: obsidian.appending(path: "snippets/\($0).css"), encoding: .utf8) }.joined(separator: "\n")
    }

    /// Obsidian's dark theme variables, in Space's colours.
    static let baseCSS = """
    body {
      --background-primary: #1C1C1E; --background-primary-alt: #232326; --background-secondary: #2A2A2D; --background-secondary-alt: #303034;
      --background-modifier-border: rgba(255,255,255,0.10); --background-modifier-border-hover: rgba(255,255,255,0.18);
      --background-modifier-hover: rgba(255,255,255,0.06); --background-modifier-active-hover: rgba(200,49,43,0.15);
      --background-modifier-form-field: rgba(255,255,255,0.06); --background-modifier-error: #E5534B; --background-modifier-success: #57AB5A;
      --text-normal: #F2F2F2; --text-muted: #9E9EA4; --text-faint: #6A6A70; --text-on-accent: #FFFFFF; --text-accent: #E8665F; --text-error: #E5534B; --text-success: #57AB5A; --text-warning: #E0A23B;
      --text-highlight-bg: rgba(242,181,68,0.28); --text-selection: rgba(200,49,43,0.3);
      --interactive-normal: #2C2C2F; --interactive-hover: #38383C; --interactive-accent: #C8312B; --interactive-accent-hover: #D9433D; --interactive-accent-rgb: 200,49,43;
      --link-color: #8FB3FF; --link-external-color: #8FB3FF; --tag-color: #C9A0FF; --tag-background: rgba(201,160,255,0.14);
      --color-red: #E5534B; --color-orange: #E0823D; --color-yellow: #E0A23B; --color-green: #57AB5A; --color-cyan: #4FB0C6; --color-blue: #539BF5; --color-purple: #B083F0; --color-pink: #E275AD;
      --color-red-rgb: 229,83,75; --color-orange-rgb: 224,130,61; --color-yellow-rgb: 224,162,59; --color-green-rgb: 87,171,90; --color-blue-rgb: 83,155,245; --color-purple-rgb: 176,131,240;
      --font-text: -apple-system, system-ui, sans-serif; --font-interface: -apple-system, system-ui, sans-serif; --font-monospace: ui-monospace, Menlo, monospace;
      --font-text-size: 16px; --font-ui-small: 13px; --font-ui-smaller: 12px; --font-ui-medium: 15px;
      --radius-s: 4px; --radius-m: 8px; --radius-l: 12px; --radius-xl: 16px; --size-4-1: 4px; --size-4-2: 8px; --size-4-3: 12px; --size-4-4: 16px;
      --checkbox-color: #C8312B; --checkbox-border-color: #6A6A70; --icon-color: #9E9EA4; --h1-size: 1.8em; --h2-size: 1.5em; --h3-size: 1.3em;
    }
    """

    /// Space's own touches after the vault's snippets: no page background (the note shows through), no scrolling.
    static let overridesCSS = """
    html, body { background: transparent !important; margin: 0; padding: 0; overflow: hidden; }
    body { color: var(--text-normal); font-family: var(--font-text); font-size: var(--font-text-size); line-height: 1.5; -webkit-font-smoothing: antialiased; }
    #space-root { padding: 2px 1px 6px; }
    a { color: var(--link-color); text-decoration: none; cursor: pointer; }
    a.tag { color: var(--tag-color); background: var(--tag-background); border-radius: 999px; padding: 0 6px; font-size: .9em; }
    code { font-family: var(--font-monospace); background: var(--background-modifier-hover); border-radius: 4px; padding: 0 4px; font-size: .9em; }
    pre { background: var(--background-modifier-hover); border-radius: 8px; padding: 10px 12px; overflow: auto; }
    button { font: inherit; color: inherit; }
    input[type=checkbox].task-list-item-checkbox { accent-color: var(--interactive-accent); margin-right: 6px; cursor: pointer; }
    ul.contains-task-list { list-style: none; padding-left: 4px; margin: 4px 0; }
    .task-list-item.is-checked .tasks-list-text { color: var(--text-muted); text-decoration: line-through; }
    .task-extras { color: var(--text-muted); font-size: .82em; }
    .task-extras .is-overdue { color: var(--color-red); }
    .tasks-backlink { font-size: .82em; color: var(--text-faint) !important; }
    .tasks-count { color: var(--text-muted); font-size: .8em; margin-top: 4px; }
    table.dataview { border-collapse: collapse; width: 100%; }
    table.dataview th, table.dataview td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--background-modifier-border); }
    .space-dv-error { border: 1px dashed var(--background-modifier-border-hover); border-radius: 10px; padding: 10px 12px; color: var(--text-muted); font-size: 13px; }
    .space-dv-error-title { font-weight: 600; color: var(--text-normal); margin-bottom: 4px; }
    .space-dv-error pre { white-space: pre-wrap; margin: 0; padding: 0; background: none; font-size: 12px; }
    #space-notices { position: fixed; top: 8px; right: 8px; display: flex; flex-direction: column; gap: 6px; z-index: 9999; }
    #space-notices .notice { background: var(--background-secondary-alt); border: 1px solid var(--background-modifier-border); border-radius: 12px; padding: 8px 12px; font-size: 13px; box-shadow: 0 6px 20px rgba(0,0,0,.35); }
    """

    @MainActor static let shim: String = {
        guard let url = Bundle.main.url(forResource: "DataviewShim", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "throw new Error('DataviewShim.js не найден в приложении')" }
        return text
    }()
}

/// Where a running block's file work goes (the open note goes through its editor, other notes to disk).
@MainActor
struct DataviewJSActions {
    var read: (String) -> String?
    var write: (String, String) -> Void
    var toggle: (String, Int) -> Void
    var open: (String) -> Void
}

#if os(macOS)
/// The note scrolls, not the widget: wheel events go on to the note's scroll view.
final class DataviewWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if let outer = enclosingScrollView { outer.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
typealias PlatformWebViewRepresentable = NSViewRepresentable
#else
final class DataviewWebView: WKWebView {}
typealias PlatformWebViewRepresentable = UIViewRepresentable
#endif

/// One ```dataviewjs block's web view. Re-runs the block (with fresh pages) a moment after notes change.
struct DataviewJSView: PlatformWebViewRepresentable {
    let code: String
    let noteID: String?
    let vault: VaultStore
    let actions: DataviewJSActions
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeWebView(_ c: Coordinator) -> DataviewWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(c, contentWorld: .page, name: "space")
        config.setURLSchemeHandler(c, forURLScheme: "space-file")
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = DataviewWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .clear
        #endif
        c.web = web
        c.load()
        return web
    }

    private func update(_ c: Coordinator) {
        let reload = c.parent.code != code || c.parent.noteID != noteID
        c.parent = self
        if reload { c.load() } else { c.vaultChanged() }
    }

    #if os(macOS)
    func makeNSView(context: Context) -> DataviewWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: DataviewWebView, context: Context) { update(context.coordinator) }
    static func dismantleNSView(_ web: DataviewWebView, coordinator: Coordinator) { coordinator.tearDown() }
    #else
    func makeUIView(context: Context) -> DataviewWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: DataviewWebView, context: Context) { update(context.coordinator) }
    static func dismantleUIView(_ web: DataviewWebView, coordinator: Coordinator) { coordinator.tearDown() }
    #endif

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler, WKNavigationDelegate {
        var parent: DataviewJSView
        weak var web: WKWebView?
        private var loadedStamp: Int?
        private var pending: Task<Void, Never>?

        init(_ parent: DataviewJSView) { self.parent = parent }

        private var root: URL? { parent.vault.rootURL }

        /// What the shim finds in window.__space.
        private func payload(withCode: Bool) -> [String: Any] {
            let cache = DataviewIndexCache.shared
            let index = cache.index(parent.vault)
            loadedStamp = cache.stamp
            let listing = cache.listing(parent.vault)
            var p: [String: Any] = [
                "pages": DataviewJS.pagesJSON(index),
                "files": listing.files,
                "folders": listing.folders,
                "current": parent.noteID ?? NSNull(),
                "vaultName": parent.vault.vaultName,
                "recent": Array(parent.vault.backStack.compactMap { s -> String? in if case .note(let id) = s { id } else { nil } }.reversed().prefix(10)),
            ]
            p["tmpdir"] = (NSTemporaryDirectory() as NSString).standardizingPath
            p["homedir"] = NSHomeDirectory()
            #if os(iOS)
            p["isMobile"] = true
            #else
            p["isMobile"] = false
            #endif
            if withCode { p["code"] = DataviewJS.code(of: parent.code) }
            return p
        }

        private static func scriptJSON(_ o: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        }

        func load() {
            pending?.cancel()
            guard let web, let root else { return }
            let current = parent.noteID.flatMap { DataviewIndexCache.shared.index(parent.vault).pages[$0] }
            var classes = ["markdown-preview-view", "markdown-rendered"]
            if case .list(let l)? = current?.fields["cssclasses"] { classes += l.map(\.plain) }
            else if case .string(let s)? = current?.fields["cssclasses"] { classes.append(s) }
            #if os(iOS)
            let bodyClass = "theme-dark is-mobile"
            #else
            let bodyClass = "theme-dark"
            #endif
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>\(DataviewJS.baseCSS)</style>
            <style>\(DataviewJS.snippetsCSS(root: root))</style>
            <style>\(DataviewJS.overridesCSS)</style>
            </head><body class="\(bodyClass)">
            <div id="space-root" class="\(classes.joined(separator: " "))"><div id="space-container" class="block-language-dataviewjs"></div></div>
            <script>window.__space = \(Self.scriptJSON(payload(withCode: true)));</script>
            <script>\(DataviewJS.shim)</script>
            </body></html>
            """
            web.loadHTMLString(html, baseURL: URL(string: "https://space.local/"))
        }

        /// Notes changed: hand the block fresh pages shortly (typing saves often; Dataview waits too).
        func vaultChanged() {
            guard DataviewIndexCache.shared.peekStamp(parent.vault) != loadedStamp else { return }
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, let web = self.web else { return }
                let json = Self.scriptJSON(self.payload(withCode: false))
                _ = try? await web.evaluateJavaScript("window.__spaceUpdate && window.__spaceUpdate(\(json))")
            }
        }

        func tearDown() {
            pending?.cancel()
            web?.configuration.userContentController.removeAllScriptMessageHandlers()
            web?.stopLoading()
        }

        // MARK: Messages from the shim

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return (nil, "bad message") }
            let path = (body["path"] as? String).map(clean)
            switch op {
            case "height":
                if let h = body["h"] as? Double, abs(parent.height - h) > 0.5 { parent.height = max(1, h) }
                return (true, nil)
            case "read":
                guard let path else { return (nil, nil) }
                return (parent.actions.read(path) ?? readFile(path), nil)
            case "readBinary":
                guard let path, let url = root?.appending(path: path), let data = try? Data(contentsOf: url) else { return (nil, nil) }
                return (data.base64EncodedString(), nil)
            case "write":
                guard let path, let text = body["text"] as? String else { return (false, nil) }
                parent.actions.write(path, text)
                return (true, nil)
            case "toggle":
                guard let path, let line = body["line"] as? Int else { return (false, nil) }
                parent.actions.toggle(path, line)
                return (true, nil)
            case "create":
                guard let path else { return (false, nil) }
                return (create(path, data: Data(((body["text"] as? String) ?? "").utf8)), nil)
            case "createBinary":
                guard let path, let b64 = body["base64"] as? String, let data = Data(base64Encoded: b64) else { return (false, nil) }
                return (create(path, data: data), nil)
            case "createFolder":
                guard let path, let url = root?.appending(path: path) else { return (false, nil) }
                let ok = (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
                if ok { Task { await parent.vault.reload() } }
                return (ok, nil)
            case "open":
                guard let path else { return (false, nil) }
                parent.actions.open(path)
                return (true, nil)
            case "openURL":
                if let s = body["url"] as? String, let url = URL(string: s) {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    await UIApplication.shared.open(url)
                    #endif
                }
                return (true, nil)
            case "http":
                return (await http(body), nil)
            case "osascript":
                guard let source = body["source"] as? String else { return (nil, "no script") }
                let widget = parent.noteID ?? "?"
                let title = parent.noteID.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "Виджет"
                return (WidgetAccess.runAppleScript(source, widget: widget, widgetTitle: title), nil)
            case "notifyPermission":
                return (await WidgetAccess.requestNotifications(), nil)
            case "notify":
                await WidgetAccess.notify(title: (body["title"] as? String) ?? "Space", body: (body["body"] as? String) ?? "", silent: (body["silent"] as? Bool) ?? false)
                return (true, nil)
            case "fsWrite":
                // Node's fs for widgets: the app's temporary folder only.
                guard let p = body["path"] as? String, WidgetAccess.isTemporary(p), let b64 = body["base64"] as? String, let data = Data(base64Encoded: b64) else { return (false, nil) }
                return ((try? data.write(to: URL(fileURLWithPath: p))) != nil, nil)
            default:
                return (nil, "unknown op \(op)")
            }
        }

        private func clean(_ p: String) -> String {
            (p.removingPercentEncoding ?? p).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        private func readFile(_ path: String) -> String? {
            guard let url = root?.appending(path: path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }

        private func create(_ path: String, data: Data) -> Bool {
            guard let url = root?.appending(path: path), !FileManager.default.fileExists(atPath: url.path) else { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .withoutOverwriting)
            } catch {
                return false
            }
            Task { await parent.vault.reload() }
            return true
        }

        /// Obsidian's requestUrl: made from Space, so sites without CORS headers work too.
        private func http(_ body: [String: Any]) async -> [String: Any]? {
            guard let s = body["url"] as? String, let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = (body["method"] as? String) ?? "GET"
            for (k, v) in (body["headers"] as? [String: String]) ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
            if let b = body["body"] as? String {
                req.httpBody = (body["binaryBody"] as? Bool) == true ? Data(base64Encoded: b) : Data(b.utf8)
            }
            guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
            return ["status": http?.statusCode ?? 200, "headers": headers, "body": data.base64EncodedString()]
        }

        // MARK: Vault files for <audio>, <img> (space-file:///path)

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let raw = task.request.url?.path ?? ""
            let path = clean(raw)
            guard let url = root?.appending(path: path), let data = try? Data(contentsOf: url) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            task.didReceive(URLResponse(url: task.request.url!, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        // Links the page itself navigates to open in the browser, not inside the widget.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            await UIApplication.shared.open(url)
            #endif
            return .cancel
        }
    }
}

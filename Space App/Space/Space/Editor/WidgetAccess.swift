import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// What widgets may do outside their web view, each behind a question to the user:
/// AppleScript to other apps (in place of Node's child_process + osascript) and system notifications.
@MainActor
enum WidgetAccess {

    /// Answers kept per widget (note) and app: "space.widgetAccess.<note>|<app>" = true / false.
    private static func key(_ widget: String, _ app: String) -> String { "space.widgetAccess.\(widget)|\(app)" }

    /// The apps a script talks to (`tell application "Music"`, `application "Spotify" is running`).
    static func targets(of source: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "application\\s+\"([^\"]+)\"", options: .caseInsensitive)
        let ns = source as NSString
        var out: [String] = []
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let app = ns.substring(with: m.range(at: 1))
            if !out.contains(app) { out.append(app) }
        }
        return out
    }

    /// Paths the script writes to inside the app's temporary folder (`POSIX file "/…/tmp/cover"`): read back after
    /// it runs, so the widget's synchronous fs.readFileSync finds them.
    static func writtenFiles(of source: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "POSIX file \"([^\"]+)\"")
        let ns = source as NSString
        let tmp = (NSTemporaryDirectory() as NSString).standardizingPath
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            .filter { ($0 as NSString).standardizingPath.hasPrefix(tmp) }
    }

    static func isTemporary(_ path: String) -> Bool {
        (path as NSString).standardizingPath.hasPrefix((NSTemporaryDirectory() as NSString).standardizingPath)
    }

    /// Runs a widget's AppleScript once the user has allowed this widget to control those apps.
    /// Returns ["out": String] or ["error": String], plus ["files": [path: base64]] it wrote.
    static func runAppleScript(_ source: String, widget: String, widgetTitle: String) -> [String: Any] {
        #if os(macOS)
        if source.range(of: "do shell script", options: .caseInsensitive) != nil {
            return ["error": "Space не выполняет «do shell script» из виджетов."]
        }
        let apps = targets(of: source)
        for app in apps {
            switch UserDefaults.standard.object(forKey: key(widget, app)) as? Bool {
            case true?: continue
            case false?: return ["error": "Доступ к «\(app)» для этого виджета запрещён. Его можно вернуть в меню виджета."]
            case nil:
                let alert = NSAlert()
                alert.messageText = "Виджет «\(widgetTitle)» хочет управлять приложением «\(app)»"
                alert.informativeText = "Виджет отправляет команды AppleScript: например, узнаёт текущий трек и переключает песни. После этого macOS один раз спросит разрешение для Space."
                alert.addButton(withTitle: "Разрешить")
                alert.addButton(withTitle: "Запретить")
                let allowed = alert.runModal() == .alertFirstButtonReturn
                UserDefaults.standard.set(allowed, forKey: key(widget, app))
                if !allowed { return ["error": "Доступ к «\(app)» запрещён."] }
            }
        }
        guard let script = NSAppleScript(source: source) else { return ["error": "Не удалось разобрать AppleScript."] }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            var message = info[NSAppleScript.errorMessage] as? String ?? "Ошибка AppleScript"
            if number == -1743 {
                message = "macOS не разрешила Space управлять этим приложением. Включите Space в Системных настройках → Конфиденциальность и безопасность → Автоматизация."
            }
            return ["error": message]
        }
        var out: [String: Any] = ["out": result.stringValue ?? ""]
        var files: [String: String] = [:]
        for path in writtenFiles(of: source) {
            if let data = FileManager.default.contents(atPath: path) { files[path] = data.base64EncodedString() }
        }
        if !files.isEmpty { out["files"] = files }
        return out
        #else
        return ["error": "Управление другими приложениями доступно только на Mac."]
        #endif
    }

    /// Apps this widget was allowed or denied, for the widget's menu.
    static func decisions(for widget: String) -> [(app: String, allowed: Bool)] {
        let prefix = "space.widgetAccess.\(widget)|"
        return UserDefaults.standard.dictionaryRepresentation().compactMap { k, v in
            guard k.hasPrefix(prefix), let b = v as? Bool else { return nil }
            return (String(k.dropFirst(prefix.count)), b)
        }.sorted { $0.app < $1.app }
    }

    static func forget(_ widget: String) {
        for d in decisions(for: widget) { UserDefaults.standard.removeObject(forKey: key(widget, d.app)) }
    }

    // MARK: Notifications

    /// Asks once (the system's own prompt) and returns "granted" or "denied", as the web Notification API does.
    static func requestNotifications() async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default:
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return ok ? "granted" : "denied"
        }
    }

    static func notify(title: String, body: String, silent: Bool) async {
        guard await requestNotifications() == "granted" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !silent { content.sound = .default }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

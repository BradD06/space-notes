import SwiftUI

/// The vault's dashboard, where the app opens. It answers "what now?": a top bar with the command bar,
/// the sky of the day (today's tasks as stars on the line of the day), the one thing to do now, the note to go
/// back to, links the map suggests, a slot for a widget — and below, the dashboard page (".space/Dashboard.md").
struct DashboardView: View {
    @Environment(VaultStore.self) private var vault
    @AppStorage("space.dashboardOverview") private var showOverview = true
    @AppStorage(Appearance.key) private var appearance = Appearance.dark.rawValue
    @State private var title = ""
    @FocusState private var editingTitle: Bool
    private let profile = VaultProfile.shared

    var body: some View {
        let index = DataviewIndexCache.shared.index(vault)
        let stars = DayPlan.stars(index)
        VStack(spacing: 12) {
            topBar
            if showOverview {
                VStack(spacing: 12) {
                    DaySkyCard(stars: stars)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                        NowCard(star: DayPlan.now(stars))
                        ContinueCard()
                        LinkCard()
                        WidgetSlot()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let url = profile.dashboardURL {
                NoteView(noteID: "dashboard", file: url).id(url)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14)
        .background(PaneBackdrop())
        .onAppear { title = profile.title }
        .onChange(of: profile.title) { _, t in if !editingTitle { title = t } }
    }

    /// The dashboard's name (click to rename) and today's date, the command bar, the theme switch.
    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                TextField(VaultProfile.defaultTitle, text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .focused($editingTitle)
                    .onSubmit { profile.setTitle(title); editingTitle = false }
                    .onChange(of: editingTitle) { _, on in if !on { profile.setTitle(title); title = profile.title } }
                    .tip("Нажми, чтобы переименовать дашборд")
                Text(Date.now.formatted(Date.FormatStyle(locale: RuDate.locale).weekday(.wide).day().month(.wide)).capitalized)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            .frame(minWidth: 140, maxWidth: 220, alignment: .leading)
            Spacer(minLength: 0)
            CommandField()
            Spacer(minLength: 0)
            RoundGlassButton(icon: showOverview ? "chevron.up" : "chevron.down",
                             help: showOverview ? "Скрыть карточки" : "Показать карточки") {
                withAnimation(.smooth(duration: 0.3)) { showOverview.toggle() }
            }
            RoundGlassButton(icon: appearance == Appearance.light.rawValue ? "moon" : "sun.max",
                             help: appearance == Appearance.light.rawValue ? "Тёмная тема" : "Светлая тема") {
                withAnimation(.smooth(duration: 0.3)) {
                    appearance = (appearance == Appearance.light.rawValue ? Appearance.dark : .light).rawValue
                }
            }
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 9)
        .background(GlassPanel(radius: 22))
    }

    static func stats(_ c: Cosmos) -> String {
        let books = c.notes.keys.filter(Books.isBook).count
        let notes = c.notes.count - books
        var parts = ["\(notes) \(plural(notes, "звезда", "звезды", "звёзд"))",
                     "\(c.universes.count) \(plural(c.universes.count, "вселенная", "вселенные", "вселенных"))"]
        if books > 0 { parts.append("\(books) \(plural(books, "книга", "книги", "книг"))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Cards

/// A card of medium glass with a heading.
private struct DashCard<Content: View>: View {
    let title: String
    var hint = ""
    var minHeight: CGFloat = 196
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Text(hint).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(GlassPanel(radius: 22))
    }
}

/// "Небо дня": today's tasks as stars along an arc from morning to night. Done stars are dim with a tick,
/// the ones ahead glow violet, the ones about to go out (late, or due within two hours) glow orange.
/// A click lights a star (ticks the task); the context menu opens its note or moves it to tomorrow.
private struct DaySkyCard: View {
    let stars: [DayStar]
    @Environment(VaultStore.self) private var vault

    static let ahead = Color(hex: 0x9C8FFF)
    static let dying = Color(hex: 0xFF9A40)

    var body: some View {
        let lit = stars.filter { $0.state == .done }.count
        let out = stars.filter { $0.state == .dying }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("Небо дня").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(stars.isEmpty ? "" : "\(lit) из \(stars.count) зажжены" + (out > 0 ? " · \(out) гаснет" : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                legend(Theme.wash.opacity(0.18), "выполнено")
                legend(Self.ahead, "впереди")
                legend(Self.dying, "гаснет")
            }
            if stars.isEmpty {
                Text("На сегодня задач нет. Задача с датой на сегодня (📅) в любой заметке появится здесь звездой, а время в её тексте, например 13:30, поставит её на линию дня.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    sky(now: context.date)
                }
                .frame(height: 150)
            }
        }
        .padding(18)
        .background(GlassPanel(radius: 22))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }

    private func sky(now: Date) -> some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height - 22
            let cal = Calendar.current
            let nowHour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
            let x: (Double) -> CGFloat = { CGFloat(($0 - DayPlan.start) / (DayPlan.end - DayPlan.start)) * w }
            // The arc of the day: a parabola from the left edge up over the middle and down to the right.
            let y: (CGFloat) -> CGFloat = { px in let t = px / max(w, 1); return h * 0.86 - 4 * t * (1 - t) * h * 0.72 }
            let nowX = min(max(x(nowHour), 0), w)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    var arc = Path(), done = Path()
                    for i in 0...80 {
                        let px = w * CGFloat(i) / 80
                        let p = CGPoint(x: px, y: y(px))
                        if i == 0 { arc.move(to: p); done.move(to: p) } else { arc.addLine(to: p); if px <= nowX { done.addLine(to: p) } }
                    }
                    ctx.stroke(arc, with: .color(Theme.wash.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 6]))
                    ctx.stroke(done, with: .color(Theme.accentText.opacity(0.75)), lineWidth: 2)
                }
                // Hours along the bottom.
                ForEach(Array(stride(from: 8, through: 22, by: 2)), id: \.self) { hr in
                    Text("\(hr):00").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.muted)
                        .fixedSize()
                        .position(x: min(max(x(Double(hr)), 16), w - 16), y: h + 14)
                }
                // Now: a thin line with its label.
                if nowHour >= DayPlan.start, nowHour <= DayPlan.end {
                    Rectangle().fill(LinearGradient(colors: [Theme.accentText, .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: 2, height: h)
                        .position(x: nowX, y: h / 2)
                    Text("сейчас " + now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ground)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentText))
                        .fixedSize()
                        .position(x: min(nowX + 44, w - 44), y: 8)
                }
                ForEach(Array(stars.enumerated()), id: \.element.id) { i, star in
                    let px = x(star.hour)
                    StarDot(star: star, labelBelow: i % 2 == 0)
                        .position(x: min(max(px, 30), w - 30), y: y(px) + (i % 2 == 0 ? 14 : -6))
                }
            }
        }
    }
}

/// One star of the day with its label; a click ticks the task.
private struct StarDot: View {
    let star: DayStar
    let labelBelow: Bool
    @Environment(VaultStore.self) private var vault
    @State private var hover = false

    var body: some View {
        let color: Color = switch star.state {
        case .done: Theme.wash.opacity(0.2)
        case .ahead: DaySkyCard.ahead
        case .dying: DaySkyCard.dying
        }
        let label = Text((star.time.isEmpty ? "" : star.time + " · ") + star.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(star.state == .done ? Theme.muted : Theme.ink)
            .strikethrough(star.state == .done)
            .lineLimit(1)
            .frame(maxWidth: 130)
            .fixedSize()
        VStack(spacing: 4) {
            if !labelBelow { label }
            Button { vault.toggle(star.task) } label: {
                ZStack {
                    Circle().fill(color).frame(width: 16, height: 16)
                        .shadow(color: star.state == .done ? .clear : color, radius: star.state == .dying ? 10 : 6)
                        .overlay(Circle().strokeBorder(star.state == .done ? Theme.line : Color.white.opacity(0.5), lineWidth: 1))
                    if star.state == .done {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.ink)
                    }
                }
                .scaleEffect(hover ? 1.25 : 1)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.smooth(duration: 0.15), value: hover)
            .accessibilityLabel("\(star.time) \(star.title), " + (star.state == .done ? "выполнено" : star.state == .dying ? "гаснет" : "впереди"))
            .tip(star.state == .done ? "Вернуть: снять отметку" : "Зажечь: отметить выполненной")
            .contextMenu {
                Button("Открыть заметку", systemImage: "doc.text") { vault.selection = .note(star.task.path) }
                if star.state != .done {
                    Button("Перенести на завтра", systemImage: "arrow.turn.down.right") { vault.postponeToTomorrow(star.task) }
                }
            }
            if labelBelow { label }
        }
    }
}

/// "Сейчас": the one thing to do now, with the time left before it goes out.
private struct NowCard: View {
    let star: DayStar?
    @Environment(VaultStore.self) private var vault

    var body: some View {
        DashCard(title: "Сейчас", hint: "важнее всего") {
            if let star {
                HStack(alignment: .center, spacing: 14) {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in timer(star, now: ctx.date) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(star.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text(where_(star)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Начать") { vault.selection = .note(star.task.path) }.buttonStyle(.spaceGlow)
                    Button("Готово") { vault.toggle(star.task) }.buttonStyle(.spaceGlass)
                    Button("На завтра") { vault.postponeToTomorrow(star.task) }.buttonStyle(.spaceGlass)
                }
            } else {
                Text("Ничего срочного. Отдыхай или выбери звезду на карте.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func where_(_ star: DayStar) -> String {
        let c = vault.cosmos
        let universe = c.universe(c.universeOf[star.task.path] ?? "")?.name
        return [universe, c.title(star.task.path)].compactMap { $0 }.joined(separator: " · ")
    }

    /// A ring that empties as the task's time comes near (two hours ahead = full).
    private func timer(_ star: DayStar, now: Date) -> some View {
        let cal = Calendar.current
        let nowHour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
        let left = star.timed && !star.overdue ? star.hour - nowHour : nil
        let fraction = left.map { min(max($0 / DayPlan.dyingWithin, 0), 1) } ?? (star.overdue ? 0 : 1)
        let color = star.state == .dying ? DaySkyCard.dying : DaySkyCard.ahead
        return ZStack {
            Circle().stroke(Theme.wash.opacity(0.13), lineWidth: 5)
            Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 5)
            VStack(spacing: 0) {
                if let left, left > 0 {
                    Text(String(format: "%d:%02d", Int(left), Int((left - floor(left)) * 60)))
                        .font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(Theme.ink)
                    Text("до срока").font(.system(size: 9)).foregroundStyle(Theme.muted)
                } else if star.overdue || (left ?? 1) <= 0 {
                    Image(systemName: "exclamationmark").font(.system(size: 16, weight: .bold)).foregroundStyle(DaySkyCard.dying)
                    Text("просрочено").font(.system(size: 9)).foregroundStyle(Theme.muted)
                } else {
                    Image(systemName: "sparkle").font(.system(size: 16, weight: .bold)).foregroundStyle(color)
                    Text("сегодня").font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(width: 70, height: 70)
    }
}

/// "Продолжить": the note edited last, with its first lines, one click away.
private struct ContinueCard: View {
    @Environment(VaultStore.self) private var vault
    @State private var hover = false

    var body: some View {
        let c = vault.cosmos
        let id = InsightsCache.insights(vault).recent.first
        DashCard(title: "Продолжить", hint: id.flatMap { c.notes[$0] }.map { "изменено " + RuDate.relative($0.modified) } ?? "") {
            if let id {
                Button { vault.selection = .note(id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(path(id, c)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        Text(c.title(id)).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(Self.excerpt(vault.text(of: id)))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink.opacity(0.8))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.wash.opacity(hover ? 0.1 : 0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
            } else {
                Text("Здесь появится заметка, с которой ты закончил.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func path(_ id: String, _ c: Cosmos) -> String {
        let universe = c.universe(c.universeOf[id] ?? "")?.name
        let constellation = c.constellationOf[id].flatMap { c.constellationName[$0] }
        return [universe, constellation].compactMap { $0 }.filter { $0 != Cosmos.looseName }.joined(separator: " · ")
    }

    /// The first lines of prose: no frontmatter, headings, code or markup.
    static func excerpt(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        var inCode = false
        var out: [String] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || t.isEmpty || t.hasPrefix("#") || t.hasPrefix("|") || t.hasPrefix("![") { continue }
            out.append(t.replacingOccurrences(of: "[*_`>\\[\\]]|^[-+] (\\[.\\] )?", with: "", options: .regularExpression))
            if out.joined().count > 220 { break }
        }
        return out.joined(separator: " ")
    }
}

/// "Связать?": links the map suggests, each with its reason and a button that writes the [[link]].
private struct LinkCard: View {
    @Environment(VaultStore.self) private var vault
    @Environment(MapModel.self) private var map
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let c = vault.cosmos
        let suggestions = InsightsCache.insights(vault).suggestions
        DashCard(title: "Связать?", hint: suggestions.isEmpty ? "" : "карта подсказывает") {
            if suggestions.isEmpty {
                Text("Пока нечего предложить: подсказки появятся, когда заметки начнут ссылаться друг на друга.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(suggestions.prefix(2), id: \.self) { s in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(c.title(s.a)).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                            Text(c.title(s.b)).lineLimit(1)
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(s.reason(c)).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("Связать") { vault.link(s, workspace: workspace) }
                        .buttonStyle(.spaceGlow)
                        .tip("Дописать [[ссылку]] в одну из заметок")
                }
            }
            if suggestions.count > 2 {
                Button("Ещё \(suggestions.count - 2) на карте") {
                    map.lens = .suggestions
                    vault.selection = .map
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            }
        }
    }
}

/// An empty place for a widget: picks a ready-made one and adds it to the dashboard page below.
private struct WidgetSlot: View {
    @Environment(VaultStore.self) private var vault
    @State private var hover = false

    private static let widgets: [(title: String, icon: String, code: String)] = [
        ("Задачи на неделю", "checklist", "```dataview\nTASK\nWHERE !completed AND due AND due <= date(today) + dur(7 days)\nSORT due ASC\n```"),
        ("Недавние заметки", "clock", "```dataview\nTABLE file.mtime AS \"Изменено\"\nSORT file.mtime DESC\nLIMIT 10\n```"),
        ("Без ссылок", "circle.dotted", "```dataview\nLIST\nWHERE length(file.inlinks) = 0 AND length(file.outlinks) = 0\nLIMIT 15\n```")
    ]

    var body: some View {
        Menu {
            ForEach(Self.widgets, id: \.title) { w in
                Button(w.title, systemImage: w.icon) { add(w.title, w.code) }
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.wash.opacity(0.13)))
                Text("Добавить виджет").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Задачи на неделю, недавние заметки, звёзды без ссылок…")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 196)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.wash.opacity(hover ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(hover ? Theme.accentText : Theme.wash.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .onHover { hover = $0 }
        .tip("Добавить виджет на страницу дашборда")
    }

    /// Appends the widget under its own heading at the end of the dashboard page.
    private func add(_ title: String, _ code: String) {
        guard let url = VaultProfile.shared.dashboardURL else { return }
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += (text.isEmpty ? "" : "\n") + "## " + title + "\n\n" + code + "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            NotificationCenter.default.post(name: .spaceVaultChangedOutside, object: nil)
        } catch {
            vault.errorMessage = "Не удалось добавить виджет: \(error.localizedDescription)"
        }
    }
}

/// A round button of glass for top bars.
struct RoundGlassButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.wash.opacity(hover ? 0.13 : 0.07)))
                .overlay(Circle().strokeBorder(Theme.glassEdge))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(help)
        .tip(help)
    }
}

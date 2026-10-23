import SwiftUI

// MARK: - The "/" menu

/// Notion's "/" menu: type "/" at the start of a line (or press "+" next to a block) and pick what to insert.
struct SlashMenu: View {
    let state: EditorState

    var body: some View {
        if state.slashVisible {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Блоки")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
                        ForEach(Array(state.slashItems.enumerated()), id: \.offset) { index, item in
                            Button { state.chooseSlash?(item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(item.swatch.map { Color(blockColor: $0) } ?? Theme.ink)
                                        .frame(width: 26, height: 26)
                                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    Text(item.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(index == state.selectedSlash ? Theme.accent.opacity(0.18) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selectedSlash) { _, i in proxy.scrollTo(i) }
            }
            .frame(width: 260)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .offset(x: state.caretPoint.x, y: state.caretPoint.y)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
    }
}

// MARK: - Formatting bar over a selection

/// A floating glass bar above selected text: inline styles, a link, and "turn into" for the whole block.
struct SelectionBar: View {
    let state: EditorState

    var body: some View {
        if let r = state.selectionRect, !state.slashVisible, state.linkQuery == nil {
            HStack(spacing: 2) {
                Menu {
                    ForEach(BlockKind.convertible, id: \.self) { kind in
                        Button(kind.title, systemImage: kind.icon) { state.turnInto?(kind) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Превратить в").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .tip("Сменить тип блока: заголовок, список, цитата…")
                Menu {
                    Button("По умолчанию", systemImage: "circle.slash") { state.setColor?(nil) }
                    Section("Текст") {
                        ForEach(BlockColor.allCases, id: \.self) { c in
                            Button(c.title) { state.setColor?(BlockTint(c, background: false)) }
                        }
                    }
                    Section("Фон") {
                        ForEach(BlockColor.allCases, id: \.self) { c in
                            Button(c.title) { state.setColor?(BlockTint(c, background: true)) }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .tip("Цвет блока")
                divider
                item("bold", "Жирный ⌘B") { state.insertMarkup?("**", "**") }
                item("italic", "Курсив ⌘I") { state.insertMarkup?("*", "*") }
                item("strikethrough", "Зачёркнутый ⌘⇧S") { state.insertMarkup?("~~", "~~") }
                item("chevron.left.forwardslash.chevron.right", "Код ⌘E") { state.insertMarkup?("`", "`") }
                item("highlighter", "Выделение ⌘⇧H") { state.insertMarkup?("==", "==") }
                item("function", "Формула ⌘⇧E") { state.insertMarkup?("$", "$") }
                divider
                item("link", "Ссылка на звезду ⌘K") { state.insertMarkup?("[[", "]]") }
            }
            .padding(.horizontal, 4)
            .foregroundStyle(Theme.ink)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            // Above the selection; below it when there is no room at the top.
            .offset(x: max(0, r.minX - 8), y: r.minY > 46 ? r.minY - 42 : r.maxY + 8)
            .transition(.opacity)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 2)
    }

    private func item(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(help)
    }
}

// MARK: - Short notices

/// "Ссылка скопирована" and the like, at the bottom of the editor for a moment.
struct EditorNotice: View {
    let state: EditorState

    var body: some View {
        if let text = state.notice {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

extension Color {
    init(blockColor c: BlockColor) {
        self.init(.sRGB, red: Double((c.hex >> 16) & 0xFF) / 255, green: Double((c.hex >> 8) & 0xFF) / 255,
                  blue: Double(c.hex & 0xFF) / 255)
    }
}

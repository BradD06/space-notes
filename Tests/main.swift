import Foundation

var failures = 0
func check<T: Equatable>(_ got: T, _ want: T, _ name: String, line: Int = #line) {
    if got != want { failures += 1; print("FAIL \(name) (line \(line))\n  got:  \(got)\n  want: \(want)") }
}

// Kinds
check(Blocks.kind(of: "> [!toggle]- Title"), .toggle, "toggle kind")
check(Blocks.kind(of: "> [!toggle-h2]+ Title"), .toggleH2, "toggle h2 kind")
check(Blocks.kind(of: "> [!note] x"), .callout, "callout kind")
check(Blocks.kind(of: "$$"), .equation, "equation kind")
check(Blocks.blocks(in: "a\n\n$$\nx\n\ny\n$$\n\nb").map(\.kind), [.text, .equation, .text], "formula is one block")

// Turn into toggles and back
check(Blocks.turn("Hello", index: 0, into: .toggle), "> [!toggle]+ Hello", "text → toggle")
check(Blocks.turn("## Title", index: 0, into: .toggleH2), "> [!toggle-h2]+ Title", "h2 → toggle h2")
check(Blocks.turn("> [!toggle-h2]+ Title\n> body", index: 0, into: .h2), "## Title\nbody", "toggle h2 → h2")

// Colours
let blue = BlockTint(.blue, background: false), blueBG = BlockTint(.blue, background: true)
check(BlockTint(calloutType: "space-blue-bg"), blueBG, "parse bg tint")
check(BlockTint(calloutType: "note"), nil, "not a tint")
check(Blocks.setColor("a\n\nHello\n\nb", index: 1, tint: blue), "a\n\n> [!space-blue]\n> Hello\n\nb", "colour text")
check(Blocks.setColor("> [!space-blue]\n> Hello", index: 0, tint: blueBG), "> [!space-blue-bg]\n> Hello", "recolour")
check(Blocks.setColor("> [!space-blue]\n> Hello", index: 0, tint: nil), "Hello", "uncolour")
check(Blocks.setColor("- a\n  - b", index: 0, tint: blue), "> [!space-blue]\n> - a\n>   - b", "colour list")
check(Blocks.setColor("> [!note] x", index: 0, tint: blue), "> [!note] x", "callouts keep their own colour")
check(Blocks.turn("> [!space-red]\n> Hello", index: 0, into: .text), "Hello", "coloured text → plain text drops colour")
check(Blocks.turn("> [!space-red]\n> Hello", index: 0, into: .h1), "> [!space-red]\n> # Hello", "coloured text → heading keeps colour")
check(Blocks.turn("> [!space-red]\n> # Hello", index: 0, into: .text), "> [!space-red]\n> Hello", "coloured heading → coloured text")
check(Blocks.tint("> [!space-red-bg]\n> x", index: 0), BlockTint(.red, background: true), "tint of block")

// Folding
check(Blocks.isFoldable("> [!toggle] T"), true, "toggle without marker folds")
check(Blocks.isFoldable("> [!note] T"), false, "plain callout doesn't fold")
check(Blocks.isFoldable("> [!note]- T"), true, "callout with marker folds")
check(Blocks.isFoldable("> [!multi-column]"), false, "columns don't fold")
check(Blocks.toggleFold("> [!toggle]+ T\n> b", index: 0), "> [!toggle]- T\n> b", "fold")
check(Blocks.toggleFold("> [!toggle]- T\n> b", index: 0), "> [!toggle]+ T\n> b", "unfold")
check(Blocks.toggleFold("> [!toggle] T", index: 0), "> [!toggle]- T", "fold without marker")
check(Blocks.toggleAllFolds("> [!toggle]+ A\n\n> [!toggle]- B"), "> [!toggle]- A\n\n> [!toggle]- B", "fold all")
check(Blocks.toggleAllFolds("> [!toggle]- A\n\n> [!toggle]- B"), "> [!toggle]+ A\n\n> [!toggle]+ B", "unfold all")

// Typing shortcuts (text already holds the typed character, caret after it)
func typed(_ t: String, _ c: String) -> String? {
    let full = t + c
    guard let e = Blocks.typingShortcut(in: full, caret: (full as NSString).length, typed: c) else { return nil }
    return (full as NSString).replacingCharacters(in: e.range, with: e.replacement)
}
check(typed("[]", " "), "- [ ] ", "[] → task")
check(typed("  [x]", " "), "  - [x] ", "[x] → done task, indented")
check(typed("\"", " "), "> ", "\" → quote")
check(typed("*", " "), "- ", "* → bullet")
check(typed("a ", " "), nil, "space after text")
check(typed("``", "`"), "```\n```", "``` gets its closing fence")
check(typed("```\ncode\n``", "`"), nil, "closing fence left alone")
check(typed("$", "$"), "$$\n\n$$", "$$ gets its closing line")
check(typed("$$\nx\n$", "$"), nil, "closing $$ left alone")
check(typed("a -", ">"), "a →", "->")
check(typed("a <", "-"), "a ←", "<-")
check(typed("a -", "-"), "a —", "--")
check(typed("-", "-"), nil, "-- at line start stays (divider)")
check(typed("a —", "-"), nil, "no dash after an em dash")
check(typed("|-", "-"), nil, "table separator")
check(typed("```\nf() -", ">"), nil, "nothing inside code")
check(typed("`a -", ">"), nil, "nothing inside inline code")
check(typed("---\ntitle: a -", ">"), nil, "nothing in frontmatter")
check(typed("---\na: b\n---\nx -", ">"), "---\na: b\n---\nx →", "after frontmatter it works")

// Block links
let idgen = { "abc123" }
check(Blocks.blockLink("Hello", index: 0, newID: idgen)?.text, "Hello ^abc123", "id appended")
check(Blocks.blockLink("Hello ^old1", index: 0, newID: idgen)?.anchor, "^old1", "existing id kept")
check(Blocks.blockLink("## Head", index: 0, newID: idgen)?.anchor, "Head", "heading links by name")
check(Blocks.blockLink("> q\n> r\nnext", index: 0, newID: idgen)?.text, "> q\n> r\n\n^abc123\n\nnext", "quote id on its own line")
check(Blocks.blockLink("> q\n\n^zz9", index: 0, newID: idgen)?.anchor, "^zz9", "existing own-line id")
check(Blocks.blockLink("---\na: 1\n---\n", index: 0, newID: idgen)?.anchor, nil, "no link to frontmatter")

// Pages
check(Blocks.page(from: "> [!toggle]+ My page\n> line 1\n> line 2", index: 0)?.title, "My page", "toggle page title")
check(Blocks.page(from: "> [!toggle]+ My page\n> line 1\n> line 2", index: 0)?.body, "line 1\nline 2", "toggle page body")
check(Blocks.page(from: "Some **bold** [[Link|alias]] text ^id1", index: 0)?.title, "Some bold alias text", "title cleaned")
check(Blocks.replace("a\n\nb\n\nc", index: 1, with: "[[B]]"), "a\n\n[[B]]\n\nc", "block replaced by link")

// Slash
check(SlashItem.items(matching: "").contains(.color(.blue)), false, "no colours in the empty menu")
check(SlashItem.items(matching: "цвет").contains(.color(.blue)), true, "colours by word")
check(SlashItem.items(matching: "toggle").first, .block(.toggle), "toggle in slash")

print(failures == 0 ? "All block tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)

import Foundation

/// A three-way merge of text, line by line. When a note changes on disk while it has edits not saved yet,
/// both the outside change and the typed edits are kept, as long as they touch different lines.
nonisolated enum TextMerge {

    /// `base` is what both sides started from (the last text saved). nil when both changed the same lines differently.
    static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == theirs || theirs == base { return mine }
        if mine == base { return theirs }
        let old = base.components(separatedBy: "\n")
        let ours = hunks(from: old, to: mine.components(separatedBy: "\n"))
        var all = ours
        for h in hunks(from: old, to: theirs.components(separatedBy: "\n")) {
            if ours.contains(h) { continue }                 // the same edit on both sides
            if ours.contains(where: { $0.clashes(with: h) }) { return nil }
            all.append(h)
        }
        var lines = old
        for h in all.sorted(by: { $0.start > $1.start }) {   // from the end, so earlier positions stay valid
            lines.replaceSubrange(h.start..<h.end, with: h.lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Lines `start..<end` of the base are replaced by `lines` (an empty range is an insertion).
    struct Hunk: Equatable {
        var start: Int, end: Int, lines: [String]

        func clashes(with o: Hunk) -> Bool {
            start == o.start || (start < o.end && o.start < end)
        }
    }

    static func hunks(from a: [String], to b: [String]) -> [Hunk] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Hunk] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) { i += 1; j += 1; continue }
            let si = i, sj = j
            while (i < a.count && removed.contains(i)) || (j < b.count && inserted.contains(j)) {
                while i < a.count, removed.contains(i) { i += 1 }
                while j < b.count, inserted.contains(j) { j += 1 }
            }
            guard i > si || j > sj else { break }
            out.append(Hunk(start: si, end: i, lines: Array(b[sj..<j])))
        }
        return out
    }
}

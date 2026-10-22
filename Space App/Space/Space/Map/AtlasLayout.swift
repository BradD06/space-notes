import SwiftUI

/// Where things go on each level of the map. Pure geometry: the same input always gives the same picture.
nonisolated enum AtlasLayout {

    // MARK: Atlas: regions sized by note count

    /// One strip of a treemap: which items it holds, and whether it is a column (else a row).
    typealias Strip = (items: Range<Int>, column: Bool)

    /// Squarified treemap: rectangles with areas proportional to `weights`, as close to square as possible,
    /// in the order given (biggest first reads best). `gap` is left between neighbours.
    /// Pass `strips` from another set of weights to keep that arrangement: then the rectangles only
    /// grow and shrink in place, so a change of weights can be animated without anything jumping.
    static func treemap(_ weights: [Double], in rect: CGRect, gap: CGFloat, strips given: [Strip]? = nil) -> [CGRect] {
        let n = weights.count
        guard n > 0, rect.width > 1, rect.height > 1 else { return Array(repeating: .zero, count: n) }
        let strips = given ?? self.strips(weights, in: rect)
        let area = areas(weights, in: rect)
        var result = Array(repeating: CGRect.zero, count: n)
        var free = rect
        for strip in strips where strip.items.upperBound <= n {
            let sum = area[strip.items].reduce(0, +)
            if strip.column {
                let w = min(free.width, CGFloat(sum / Double(max(free.height, 0.001))))
                var y = free.minY
                for k in strip.items {
                    let h = CGFloat(area[k]) / max(w, 0.001)
                    result[k] = CGRect(x: free.minX, y: y, width: w, height: h)
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
            } else {
                let h = min(free.height, CGFloat(sum / Double(max(free.width, 0.001))))
                var x = free.minX
                for k in strip.items {
                    let w = CGFloat(area[k]) / max(h, 0.001)
                    result[k] = CGRect(x: x, y: free.minY, width: w, height: h)
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
            }
        }
        // Gaps only between neighbours, not along the outer edge.
        return result.map { r in
            let left = r.minX > rect.minX + 0.5 ? gap / 2 : 0, right = r.maxX < rect.maxX - 0.5 ? gap / 2 : 0
            let top = r.minY > rect.minY + 0.5 ? gap / 2 : 0, bottom = r.maxY < rect.maxY - 0.5 ? gap / 2 : 0
            return CGRect(x: r.minX + left, y: r.minY + top, width: max(0, r.width - left - right), height: max(0, r.height - top - bottom))
        }
    }

    private static func areas(_ weights: [Double], in rect: CGRect) -> [Double] {
        let total = max(weights.reduce(0, +), 0.0001)
        let scale = Double(rect.width * rect.height) / total
        return weights.map { max($0, 0.0001) * scale }
    }

    /// The squarified arrangement: strips filled while they keep their rectangles close to square.
    static func strips(_ weights: [Double], in rect: CGRect) -> [Strip] {
        let n = weights.count
        guard n > 0, rect.width > 1, rect.height > 1 else { return [] }
        let area = areas(weights, in: rect)
        func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
            let sum = row.reduce(0, +), hi = row.max() ?? 0, lo = row.min() ?? 1
            return max(side * side * hi / (sum * sum), sum * sum / (side * side * lo))
        }
        var out: [Strip] = []
        var free = rect
        var i = 0
        while i < n {
            let side = Double(min(free.width, free.height))
            var j = i + 1
            while j < n, worst(area[i...j], side) <= worst(area[i..<j], side) { j += 1 }
            let sum = area[i..<j].reduce(0, +)
            let column = free.width >= free.height
            out.append((i..<j, column))
            if column {
                let w = CGFloat(sum / Double(free.height))
                free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
            } else {
                let h = CGFloat(sum / Double(free.width))
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
            }
            i = j
        }
        return out
    }

    /// Room for the title of a region.
    static let regionHeader: CGFloat = 58
    static let regionPadding: CGFloat = 14

    struct Region {
        let groupID: String
        let frame: CGRect
        /// Constellation id → its box inside the region.
        let constellations: [(id: String, frame: CGRect)]
    }

    /// Regions for every group, with their constellations inside. Small groups still get room for a title.
    /// `boost` scales groups' shares (a hovered universe grows, the rest give way) while keeping the arrangement.
    static func regions(_ atlas: Atlas, in rect: CGRect, boost: [Double]? = nil) -> [Region] {
        let weights = baseWeights(atlas)
        let arrangement = Self.strips(weights, in: rect)
        let base = treemap(weights, in: rect, gap: 20, strips: arrangement)
        let boosted = boost.map { b in weights.enumerated().map { $1 * (b.indices.contains($0) ? b[$0] : 1) } } ?? weights
        let frames = boost == nil ? base : treemap(boosted, in: rect, gap: 20, strips: arrangement)
        func inner(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX + regionPadding, y: frame.minY + regionHeader,
                   width: frame.width - 2 * regionPadding, height: frame.height - regionHeader - regionPadding)
        }
        return atlas.groups.indices.map { i in
            let g = atlas.groups[i]
            let cw = g.constellations.map { max(Double($0.count), Double(g.count) * 0.08) }
            let boxes = treemap(cw, in: inner(frames[i]), gap: 10, strips: Self.strips(cw, in: inner(base[i])))
            return Region(groupID: g.id, frame: frames[i], constellations: zip(g.constellations, boxes).map { ($0.id, $1) })
        }
    }

    static func baseWeights(_ atlas: Atlas) -> [Double] {
        let total = Double(max(atlas.total, 1))
        return atlas.groups.map { max(Double($0.count), total * 0.06) }
    }

    /// How much the hovered group grows: to about a third of the atlas, at least nearly double, at most six times.
    static func focusBoost(_ atlas: Atlas, focused: String?) -> [Double] {
        let weights = baseWeights(atlas)
        guard let focused, let i = atlas.groups.firstIndex(where: { $0.id == focused }) else { return weights.map { _ in 1 } }
        let w = weights[i], rest = weights.reduce(0, +) - w
        let m = min(6, max(1.8, 0.34 * rest / (0.66 * max(w, 0.0001))))
        return weights.indices.map { $0 == i ? m : 1 }
    }

    /// Two regions touch when they face each other across a gap: then their links sit on the shared border.
    static func sharedBorder(_ a: CGRect, _ b: CGRect, gap: CGFloat = 26) -> (CGPoint, CGPoint)? {
        let overlapX = (max(a.minX, b.minX), min(a.maxX, b.maxX))
        let overlapY = (max(a.minY, b.minY), min(a.maxY, b.maxY))
        if overlapY.1 - overlapY.0 > 30 {
            let y = (overlapY.0 + overlapY.1) / 2
            if abs(b.minX - a.maxX) < gap { return (CGPoint(x: a.maxX, y: y), CGPoint(x: b.minX, y: y)) }
            if abs(a.minX - b.maxX) < gap { return (CGPoint(x: b.maxX, y: y), CGPoint(x: a.minX, y: y)) }
        }
        if overlapX.1 - overlapX.0 > 30 {
            let x = (overlapX.0 + overlapX.1) / 2
            if abs(b.minY - a.maxY) < gap { return (CGPoint(x: x, y: a.maxY), CGPoint(x: x, y: b.minY)) }
            if abs(a.minY - b.maxY) < gap { return (CGPoint(x: x, y: b.maxY), CGPoint(x: x, y: a.minY)) }
        }
        return nil
    }

    // MARK: Stars inside an area

    static let golden = Double.pi * (3 - sqrt(5))

    /// Sunflower placement: the first (most linked) star in the middle, the next ones spiralling outwards.
    /// Even spacing, nothing overlaps, and the brightest stars are where the eye goes first.
    static func sunflower(count: Int, center: CGPoint, rx: CGFloat, ry: CGFloat, hasHead: Bool) -> [CGPoint] {
        guard count > 0 else { return [] }
        var points: [CGPoint] = []
        let rest = hasHead ? count - 1 : count
        if hasHead { points.append(center) }
        for k in 0..<rest {
            let r = sqrt((Double(k) + (hasHead ? 1.2 : 0.5)) / Double(rest + (hasHead ? 1 : 0)))
            let a = Double(k) * golden
            points.append(CGPoint(x: center.x + rx * CGFloat(r * cos(a)), y: center.y + ry * CGFloat(r * sin(a))))
        }
        return points
    }

    // MARK: Universe: constellations in order

    struct Zone {
        let id: String
        let center: CGPoint
        let radius: CGFloat
    }

    /// Constellations as circles in reading order, sized by note count, with room above each for its title.
    static func zones(_ constellations: [Atlas.Constellation], in rect: CGRect) -> [Zone] {
        let n = constellations.count
        guard n > 0, rect.width > 40, rect.height > 40 else { return [] }
        // The grid that leaves the biggest cells.
        var best = (cols: 1, side: CGFloat(0))
        for cols in 1...n {
            let rows = Int(ceil(Double(n) / Double(cols)))
            let side = min(rect.width / CGFloat(cols), rect.height / CGFloat(rows))
            if side > best.side { best = (cols, side) }
        }
        let cols = best.cols, rows = Int(ceil(Double(n) / Double(cols)))
        let cellW = rect.width / CGFloat(cols), cellH = rect.height / CGFloat(rows)
        let maxR = max(24, min(cellW / 2 - 18, (cellH - 56) / 2 - 8))
        let biggest = Double(constellations.map(\.count).max() ?? 1)
        return constellations.enumerated().map { i, c in
            let row = i / cols, col = i % cols
            // The last row is centred, and every other row sits a little lower, so it doesn't read as a table.
            let inRow = row == rows - 1 ? n - row * cols : cols
            let shift = CGFloat(cols - inRow) * cellW / 2
            let r = maxR * CGFloat(0.45 + 0.55 * sqrt(Double(c.count) / biggest))
            let jitter = (col % 2 == 0 ? -1 : 1) * min(cellH * 0.06, 18)
            let center = CGPoint(x: rect.minX + shift + cellW * (CGFloat(col) + 0.5),
                                 y: rect.minY + cellH * (CGFloat(row) + 0.5) + 22 + (rows > 1 || cols > 1 ? jitter : 0))
            return Zone(id: c.id, center: center, radius: r)
        }
    }

    /// Where a line between two circles leaves the first and enters the second.
    /// A line coming from above stops short of the circle's title, so the two never cross.
    static func chord(_ a: Zone, _ b: Zone) -> (CGPoint, CGPoint) {
        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
        let d = max(hypot(dx, dy), 0.001)
        let title = 48 * (dy / d) * (dy / d)
        let ra = a.radius + (dy < 0 ? title : 0), rb = b.radius + (dy > 0 ? title : 0)
        return (CGPoint(x: a.center.x + dx / d * ra, y: a.center.y + dy / d * ra),
                CGPoint(x: b.center.x - dx / d * rb, y: b.center.y - dy / d * rb))
    }

    /// The bands worth drawing: the strongest pairs whose line doesn't run through a third constellation.
    static func bands(_ bridges: [Atlas.Bridge], zones: [Zone], limit: Int = 10) -> [(Atlas.Bridge, CGPoint, CGPoint)] {
        let byID = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, $0) })
        var out: [(Atlas.Bridge, CGPoint, CGPoint)] = []
        for b in bridges where out.count < limit {
            guard let za = byID[b.a], let zb = byID[b.b] else { continue }
            let blocked = zones.contains { z in
                guard z.id != za.id, z.id != zb.id else { return false }
                return distance(from: z.center, toSegment: za.center, zb.center) < z.radius + 6
            }
            guard !blocked else { continue }
            let (p, q) = chord(za, zb)
            guard (q.x - p.x) * (zb.center.x - za.center.x) + (q.y - p.y) * (zb.center.y - za.center.y) > 0 else { continue }
            out.append((b, p, q))
        }
        return out
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: A tiny vault: every star on one screen

    /// A small spring layout: linked notes pull together, all notes push apart. Fixed start, fixed steps.
    static func spread(_ ids: [String], cosmos: Cosmos, in rect: CGRect) -> [String: CGPoint] {
        let n = ids.count
        guard n > 0 else { return [:] }
        if n == 1 { return [ids[0]: CGPoint(x: rect.midX, y: rect.midY)] }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var p = ids.enumerated().map { i, _ -> CGPoint in
            let a = Double(i) / Double(n) * 2 * .pi
            return CGPoint(x: cos(a), y: sin(a) * 0.8)
        }
        let links: [(Int, Int)] = cosmos.edges.compactMap { e in
            guard let a = index[e.a], let b = index[e.b] else { return nil }
            return (a, b)
        }
        let k = 1.6 / sqrt(Double(n))
        for step in 0..<300 {
            let t = 0.1 * (1 - Double(step) / 300) + 0.005
            var force = Array(repeating: CGVector.zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = Double(p[i].x - p[j].x), dy = Double(p[i].y - p[j].y)
                    var d = hypot(dx, dy)
                    if d < 0.001 { dx = 0.01; dy = 0.01 * Double(i - j); d = hypot(dx, dy) }
                    let f = k * k / d
                    force[i].dx += dx / d * f; force[i].dy += dy / d * f
                    force[j].dx -= dx / d * f; force[j].dy -= dy / d * f
                }
            }
            for (a, b) in links {
                let dx = Double(p[a].x - p[b].x), dy = Double(p[a].y - p[b].y)
                let d = max(hypot(dx, dy), 0.001)
                let f = d * d / k
                force[a].dx -= dx / d * f; force[a].dy -= dy / d * f
                force[b].dx += dx / d * f; force[b].dy += dy / d * f
            }
            for i in 0..<n {
                // A weak pull to the middle keeps lonely notes from drifting off.
                force[i].dx -= Double(p[i].x) * 0.3; force[i].dy -= Double(p[i].y) * 0.3
                let len = max(hypot(force[i].dx, force[i].dy), 0.0001)
                let move = min(len, t)
                p[i].x += CGFloat(force[i].dx / len * move)
                p[i].y += CGFloat(force[i].dy / len * move)
            }
        }
        let xs = p.map(\.x), ys = p.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let w = max(maxX - minX, 0.001), h = max(maxY - minY, 0.001)
        var out: [String: CGPoint] = [:]
        var screen = p.map { CGPoint(x: rect.minX + ($0.x - minX) / w * rect.width, y: rect.minY + ($0.y - minY) / h * rect.height) }
        // Every star carries its name below it: push apart the ones whose names would touch.
        let need = CGSize(width: 190, height: 64)
        for _ in 0..<120 {
            var moved = false
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = screen[j].x - screen[i].x, dy = screen[j].y - screen[i].y
                    let ox = need.width - abs(dx), oy = need.height - abs(dy)
                    guard ox > 0, oy > 0 else { continue }
                    moved = true
                    // Move along the axis that needs less.
                    if ox / need.width < oy / need.height {
                        let s: CGFloat = dx >= 0 ? 1 : -1
                        screen[i].x -= s * ox / 2; screen[j].x += s * ox / 2
                    } else {
                        let s: CGFloat = dy >= 0 ? 1 : -1
                        screen[i].y -= s * oy / 2; screen[j].y += s * oy / 2
                    }
                }
            }
            for i in 0..<n {
                screen[i].x = min(max(screen[i].x, rect.minX), rect.maxX)
                screen[i].y = min(max(screen[i].y, rect.minY), rect.maxY)
            }
            if !moved { break }
        }
        for (i, id) in ids.enumerated() { out[id] = screen[i] }
        return out
    }
}

/// Colours and marks shared by every level of the map.
@MainActor
enum MapStyle {
    /// The colour of a group: the one the user gave the universe, else the palette in size order.
    static func color(_ group: String?, atlas: Atlas) -> Color {
        guard let group else { return Theme.muted }
        if group == Atlas.othersID { return Color(hex: 0x8E98A8) }
        if atlas.colorsFollowUniverses, let hex = UniverseColors.shared.hexes[group] { return Color(hex: hex) }
        return Theme.color(forUniverseIndex: atlas.rank(of: group))
    }

    static func color(ofNote id: String, atlas: Atlas) -> Color { color(atlas.groupOf[id], atlas: atlas) }

    /// Star size from its links.
    static func radius(_ degree: Int) -> CGFloat { 1.6 + min(4.4, 0.9 * log2(1 + CGFloat(degree))) }

    /// Bright when recently touched, dim when not opened for months.
    static func freshness(_ modified: Date?, now: Date = .now) -> Double {
        guard let modified else { return 0.5 }
        let days = now.timeIntervalSince(modified) / 86_400
        return max(0.35, min(1, 1 - 0.65 * (days - 7) / 173))
    }

    static func lensColor(_ lens: MapModel.Lens) -> Color {
        switch lens {
        case .suggestions: Color(hex: 0x7FD1A8)
        case .orphans: Color(hex: 0xE8826B)
        case .forgotten: Color(hex: 0xC9A0FF)
        }
    }

    /// "94 заметки"
    static func notes(_ n: Int) -> String { "\(n.formatted()) \(plural(n, "заметка", "заметки", "заметок"))" }
    static func links(_ n: Int) -> String { "\(n.formatted()) \(plural(n, "связь", "связи", "связей"))" }
}

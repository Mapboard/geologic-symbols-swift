import CoreGraphics
import CoreText
import Foundation

/// What a feature says about itself: the modifiers in an id (`+inferred+questionable`) and the side its
/// decorations go on.
public struct LineModifiers: Sendable {
    public var location: LineLocation
    public var questionable: Bool
    /// 1: decorations right of travel (the right-hand rule); -1: left.
    public var side: Int

    public init(location: LineLocation = .accurate, questionable: Bool = false, side: Int = 1) {
        self.location = location
        self.questionable = questionable
        self.side = side
    }

    /// From an id's modifiers; unknown ones are ignored.
    public init(_ modifiers: [String], side: Int = 1) {
        self.init(side: side)
        for m in modifiers {
            if let l = LineLocation(rawValue: m) { location = l }
            if m == "questionable" { questionable = true }
        }
    }
}

/// How to draw a line: colour, weight and scale, and FGDC's drawing option.
public struct LineStyle: @unchecked Sendable {
    /// nil uses the line's ink.
    public var ink: CGColor?
    /// Colour of `#ffffff` knock-outs; nil clears them.
    public var background: CGColor?
    /// Multiplies stroke widths, including the decorations' strokes.
    public var weight: CGFloat
    /// Drawing units per millimetre: 72/25.4 draws at map scale in points.
    public var unitsPerMM: CGFloat
    public var option: Int
    /// Text for label layers, a feature's value; nil uses the layer's fallback.
    public var label: String?

    public init(ink: CGColor? = nil, background: CGColor? = nil, weight: CGFloat = 1, unitsPerMM: CGFloat = 72 / 25.4,
                option: Int = 1, label: String? = nil) {
        self.ink = ink
        self.background = background
        self.weight = weight
        self.unitsPerMM = unitsPerMM
        self.option = option
        self.label = label
    }

    /// Style arguments from an id: colours (ink, background), `weight=`, `scale=` (multiplies `unitsPerMM`),
    /// `option=`.
    public func applying(_ args: [String]) -> LineStyle {
        var style = self
        let parsed = StyleArguments(args)
        if let ink = parsed.style.ink { style.ink = ink }
        if let background = parsed.style.background { style.background = background }
        style.weight *= parsed.style.weight
        style.unitsPerMM *= parsed.scale
        for arg in args where arg.hasPrefix("option=") {
            if let n = Int(arg.dropFirst(7)) { style.option = n }
        }
        return style
    }
}

/// The sample paths previews draw along, the same on every platform.
public enum LineSample: Sendable {
    case straight
    /// Two gentle bends, as the standard draws its line swatches (`wavyPath` in the TypeScript composer).
    case wavy

    public func points(in rect: CGRect) -> [CGPoint] {
        switch self {
        case .straight:
            return [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]
        case .wavy:
            let n = 48
            let amp = rect.height / 6
            return (0...n).map { i in
                let t = CGFloat(i) / CGFloat(n)
                let y = amp * sin(t * 2 * .pi - .pi / 2) * 0.9 + amp * 0.35 * sin(t * 4 * .pi)
                return CGPoint(x: rect.minX + t * rect.width, y: rect.midY + y)
            }
        }
    }
}

/// A glyph a line places, found in its catalog.
public struct PlacedGlyph {
    public var drawing: Drawing
    public var item: SymbolItem
}

/// Draws line items along a path with the canonical placement rule (spec/collections.md, "The line kind").
public enum LineRenderer {
    /// Draws into a y-down context. `glyph` looks up the glyphs the line places by their reference.
    public static func draw(
        _ line: LineProperties, defaults: LineDefaults?, along points: [CGPoint], in context: CGContext,
        modifiers: LineModifiers = LineModifiers(), style: LineStyle = LineStyle(),
        glyph: @escaping (String) -> PlacedGlyph?
    ) {
        let path = Polyline(points)
        guard path.length > 0 else { return }
        let k = style.unitsPerMM
        let ink = style.ink ?? line.ink.flatMap(parseHex).map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
            ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let side: CGFloat = (line.oriented ?? false) && modifiers.side == -1 ? -1 : 1
        let rule = line.dash ?? defaults?.dash
        let painter = LinePainter(context: context, path: path, k: k, side: side, ink: ink, style: style, glyph: glyph)

        var decorations: [CGFloat] = []
        for layer in line.layers(option: style.option) {
            switch layer {
            case .stroke(let s):
                painter.stroke(s, dash: dashLengths(s, rule: rule, location: modifiers.location))
            case .place(let p):
                let drawn = p.locations ?? LineLocation.allCases.filter { $0 != .concealed }
                guard drawn.contains(modifiers.location) else { continue }
                let at = positions(p, length: path.length, k: k)
                if p.at ?? "interval" == "interval" { decorations = at }
                painter.place(p, at: at)
            case .label(let l):
                painter.label(l, at: positions(interval: l.interval.map { $0 * k }, length: path.length))
            }
        }
        if modifiers.questionable, let q = line.questionable ?? defaults?.questionable {
            // At its own interval, each moved to the nearest gap between decorations.
            var at: [CGFloat] = positions(interval: (q.interval ?? 30) * k, length: path.length)
            let gaps = zip(decorations, decorations.dropFirst()).map { ($0 + $1) / 2 }
            if !gaps.isEmpty {
                at = Array(Set(at.map { s in gaps.min { abs($0 - s) < abs($1 - s) }! })).sorted()
            }
            var mark = q
            mark.rotate = "upright"
            painter.place(mark, at: at)
        }
    }

    /// Dash lengths in drawing units for a stroke in a location state, or nil for solid.
    static func dashLengths(_ s: StrokeLayer, rule: LocationDash?, location: LineLocation) -> [Double]? {
        switch s.dash ?? .location {
        case .none: return nil
        case .lengths(let l): return l
        case .location: return rule?.lengths(location).map { $0.map { $0 * s.width } }
        }
    }

    /// Arc lengths for a place layer: centred repeats, or the named positions.
    static func positions(_ p: PlaceLayer, length: CGFloat, k: CGFloat) -> [CGFloat] {
        switch p.at ?? "interval" {
        case "middle": return [length / 2]
        case "start": return [0]
        case "end": return [length]
        case "ends": return [0, length]
        default: return positions(interval: p.interval.map { $0 * k }, length: length)
        }
    }

    /// n = max(1, ⌊L / interval⌋) repeats, centred on the line.
    static func positions(interval: CGFloat?, length: CGFloat) -> [CGFloat] {
        guard let interval, interval > 0 else { return [length / 2] }
        let n = max(1, Int(length / interval))
        let start = (length - CGFloat(n - 1) * interval) / 2
        return (0..<n).map { start + CGFloat($0) * interval }
    }
}

private struct LinePainter {
    let context: CGContext
    let path: Polyline
    let k: CGFloat
    let side: CGFloat
    let ink: CGColor
    let style: LineStyle
    let glyph: (String) -> PlacedGlyph?

    func stroke(_ s: StrokeLayer, dash: [Double]?) {
        let pts = path.offset((s.offset ?? 0) * k * side)
        guard let first = pts.first else { return }
        context.saveGState()
        context.beginPath()
        context.move(to: first)
        for p in pts.dropFirst() { context.addLine(to: p) }
        if s.ink == "#ffffff" {
            if let background = style.background {
                context.setStrokeColor(background)
            } else {
                context.setBlendMode(.clear)
            }
        } else {
            context.setStrokeColor(ink)
        }
        context.setLineWidth(s.width * k * style.weight)
        context.setLineCap(lineCap(s.cap))
        context.setLineJoin(lineJoin(s.join))
        if let dash {
            context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) * k * style.weight })
        }
        context.strokePath()
        context.restoreGState()
    }

    func place(_ p: PlaceLayer, at positions: [CGFloat]) {
        guard let g = glyph(p.glyph) else { return }
        let vb = g.drawing.viewBox.size
        let nominal = g.item.glyph?.size.map { max($0.width, $0.height) } ?? 5
        let size = (p.size ?? nominal) * k
        let longest = max(vb.width, vb.height, 0.0001)
        let box = CGSize(width: size * vb.width / longest, height: size * vb.height / longest)
        let anchor = g.item.glyph?.anchor ?? [0.5, 0.5]
        let rect = CGRect(x: -box.width * anchor[0], y: -box.height * anchor[1], width: box.width, height: box.height)
        let upright = p.rotate == "upright"
        let glyphStyle = SymbolStyle(ink: ink, background: style.background, weight: style.weight)
        for s in positions {
            let (point, angle) = path.at(s)
            let normal = CGPoint(x: -sin(angle), y: cos(angle))
            let d = (p.offset ?? 0) * k * side
            context.saveGState()
            context.translateBy(x: point.x + normal.x * d, y: point.y + normal.y * d)
            context.rotate(by: angle)
            if upright {
                if cos(angle) < 0 { context.rotate(by: .pi) }
            } else if side < 0 {
                context.scaleBy(x: 1, y: -1)
            }
            SymbolRenderer.draw(g.drawing, in: context, rect: rect, style: glyphStyle,
                                recolorable: g.item.recolorable, preserveAspect: true, fillsBackground: false)
            context.restoreGState()
        }
    }

    func label(_ l: LabelLayer, at positions: [CGFloat]) {
        guard let text = style.label ?? l.text.fallback, !text.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(.system, (l.size ?? 3) * k, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, (l.size ?? 3) * k, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ink] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
        let ctLine = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        for s in positions {
            let (point, angle) = path.at(s)
            let normal = CGPoint(x: -sin(angle), y: cos(angle))
            let d = (l.offset ?? 0) * k * side
            context.saveGState()
            context.translateBy(x: point.x + normal.x * d, y: point.y + normal.y * d)
            context.rotate(by: cos(angle) < 0 ? angle + .pi : angle)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: -width / 2, y: (ascent - descent) / 2)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    func lineCap(_ s: String?) -> CGLineCap {
        switch s {
        case "butt": return .butt
        case "square": return .square
        default: return .round
        }
    }

    func lineJoin(_ s: String?) -> CGLineJoin {
        switch s {
        case "miter": return .miter
        case "bevel": return .bevel
        default: return .round
        }
    }
}

/// A path as a polyline, measured by arc length.
struct Polyline {
    let points: [CGPoint]
    private var cumulative: [CGFloat] = [0]

    init(_ points: [CGPoint]) {
        self.points = points
        for i in points.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
    }

    var length: CGFloat { cumulative.last ?? 0 }

    /// The point at arc length `s` and the tangent's angle there.
    func at(_ s: CGFloat) -> (CGPoint, CGFloat) {
        guard points.count > 1 else { return (points.first ?? .zero, 0) }
        let s = min(max(s, 0), length)
        var i = 1
        while i < cumulative.count - 1 && cumulative[i] < s { i += 1 }
        let a = points[i - 1], b = points[i]
        let segment = max(cumulative[i] - cumulative[i - 1], 1e-9)
        let f = (s - cumulative[i - 1]) / segment
        return (CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), atan2(b.y - a.y, b.x - a.x))
    }

    /// The path moved `d` to the right of travel, mitred at vertices.
    func offset(_ d: CGFloat) -> [CGPoint] {
        guard d != 0, points.count > 1 else { return points }
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let len = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
            return CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
        }
        return points.indices.map { i in
            let before = i > 0 ? normal(points[i - 1], points[i]) : nil
            let after = i < points.count - 1 ? normal(points[i], points[i + 1]) : nil
            let n0 = before ?? after!, n1 = after ?? before!
            var m = CGPoint(x: n0.x + n1.x, y: n0.y + n1.y)
            let len = max(hypot(m.x, m.y), 1e-9)
            m = CGPoint(x: m.x / len, y: m.y / len)
            // Limit the mitre so sharp vertices don't throw the offset far out.
            let cosHalf = max(m.x * n0.x + m.y * n0.y, 0.25)
            return CGPoint(x: points[i].x + m.x * d / cosHalf, y: points[i].y + m.y * d / cosHalf)
        }
    }
}

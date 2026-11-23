import CoreGraphics
import Foundation

/// Parsed artwork in the pattern or glyph contract: shapes and groups with transforms, paint and clips.
public struct Drawing: @unchecked Sendable {
    public var viewBox: CGRect
    var root: Node
    var clips: [String: CGPath]
}

indirect enum Node {
    case group(transform: CGAffineTransform, paint: Paint, clip: String?, children: [Node])
    case shape(path: CGPath, transform: CGAffineTransform, paint: Paint, clip: String?)
}

enum PaintValue: Equatable {
    case none
    case currentColor
    case rgb(CGFloat, CGFloat, CGFloat)

    static let white = PaintValue.rgb(1, 1, 1)

    init?(_ s: String) {
        let v = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch v {
        case "none", "transparent": self = .none
        case "currentcolor": self = .currentColor
        case "black": self = .rgb(0, 0, 0)
        case "white": self = .white
        default:
            guard let rgb = parseHex(v) else { return nil }
            self = .rgb(rgb.0, rgb.1, rgb.2)
        }
    }
}

func parseHex(_ s: String) -> (CGFloat, CGFloat, CGFloat)? {
    var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
    return (CGFloat((n >> 16) & 0xff) / 255, CGFloat((n >> 8) & 0xff) / 255, CGFloat(n & 0xff) / 255)
}

/// Paint properties as set on one element; nil inherits from the parent.
struct Paint {
    var fill: PaintValue?
    var stroke: PaintValue?
    var strokeWidth: CGFloat?
    var lineCap: CGLineCap?
    var lineJoin: CGLineJoin?
    var miterLimit: CGFloat?
    var evenOdd: Bool?
    var dash: [CGFloat]?
    var dashOffset: CGFloat?

    /// SVG's initial values.
    static let initial = Paint(
        fill: .rgb(0, 0, 0), stroke: PaintValue.none, strokeWidth: 1, lineCap: .butt, lineJoin: .miter,
        miterLimit: 4, evenOdd: false, dash: [], dashOffset: 0
    )

    func inheriting(_ parent: Paint) -> Paint {
        Paint(
            fill: fill ?? parent.fill, stroke: stroke ?? parent.stroke, strokeWidth: strokeWidth ?? parent.strokeWidth,
            lineCap: lineCap ?? parent.lineCap, lineJoin: lineJoin ?? parent.lineJoin,
            miterLimit: miterLimit ?? parent.miterLimit, evenOdd: evenOdd ?? parent.evenOdd,
            dash: dash ?? parent.dash, dashOffset: dashOffset ?? parent.dashOffset
        )
    }
}

public enum DrawingError: Error, CustomStringConvertible {
    case invalidXML(String)
    case noViewBox
    case unsupportedElement(String)
    case invalidAttribute(String, String)

    public var description: String {
        switch self {
        case .invalidXML(let m): return "invalid XML: \(m)"
        case .noViewBox: return "no viewBox"
        case .unsupportedElement(let e): return "<\(e)> is outside the symbol contracts"
        case .invalidAttribute(let k, let v): return "cannot read \(k)=\"\(v)\""
        }
    }
}

extension Drawing {
    /// Parses contract SVG. `viewBox` and `body` let a compiled source collection's inline artwork be read too.
    public init(svg: Data) throws {
        let tree = try XMLTree.parse(svg)
        guard tree.name == "svg" else { throw DrawingError.unsupportedElement(tree.name) }
        guard let vb = tree.attributes["viewBox"] else { throw DrawingError.noViewBox }
        let n = try NumberScanner.numbers(vb)
        guard n.count == 4 else { throw DrawingError.invalidAttribute("viewBox", vb) }
        viewBox = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        var clips: [String: CGPath] = [:]
        for defs in tree.children where defs.name == "defs" {
            for clip in defs.children where clip.name == "clipPath" {
                guard let id = clip.attributes["id"] else { continue }
                let path = CGMutablePath()
                for child in clip.children {
                    if case .shape(let p, let t, _, _) = try node(child) { path.addPath(p, transform: t) }
                }
                clips[id] = path
            }
        }
        self.clips = clips
        root = .group(transform: .identity, paint: try paint(tree), clip: nil, children: try tree.children.compactMap(node))
    }

    public init(viewBox: String, body: String) throws {
        try self.init(svg: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(viewBox)\">\(body)</svg>".utf8))
    }
}

private func node(_ el: XMLTree) throws -> Node? {
    let transform = try parseTransform(el.attributes["transform"])
    let p = try paint(el)
    let clip = el.attributes["clip-path"].map {
        $0.replacingOccurrences(of: "url(#", with: "").replacingOccurrences(of: ")", with: "")
    }
    func num(_ key: String, _ fallback: CGFloat = 0) throws -> CGFloat {
        guard let s = el.attributes[key] else { return fallback }
        guard let v = try NumberScanner.numbers(s).first else { throw DrawingError.invalidAttribute(key, s) }
        return v
    }
    let path = CGMutablePath()
    switch el.name {
    case "defs", "title", "desc", "metadata":
        return nil
    case "g":
        return .group(transform: transform, paint: p, clip: clip, children: try el.children.compactMap(node))
    case "path":
        let d = el.attributes["d"] ?? ""
        do {
            path.addPath(try parsePathData(d))
        } catch {
            throw DrawingError.invalidAttribute("d", String(d.prefix(40)))
        }
    case "rect":
        let rect = CGRect(x: try num("x"), y: try num("y"), width: try num("width"), height: try num("height"))
        var rx = try num("rx", -1), ry = try num("ry", -1)
        if rx < 0 { rx = max(ry, 0) }
        if ry < 0 { ry = rx }
        if rx > 0 {
            path.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
        } else {
            path.addRect(rect)
        }
    case "circle":
        let r = try num("r")
        path.addEllipse(in: CGRect(x: try num("cx") - r, y: try num("cy") - r, width: 2 * r, height: 2 * r))
    case "ellipse":
        let rx = try num("rx"), ry = try num("ry")
        path.addEllipse(in: CGRect(x: try num("cx") - rx, y: try num("cy") - ry, width: 2 * rx, height: 2 * ry))
    case "line":
        path.move(to: CGPoint(x: try num("x1"), y: try num("y1")))
        path.addLine(to: CGPoint(x: try num("x2"), y: try num("y2")))
    case "polyline", "polygon":
        let n = try NumberScanner.numbers(el.attributes["points"] ?? "")
        let points = stride(from: 0, to: n.count - 1, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) }
        path.addLines(between: points)
        if el.name == "polygon" { path.closeSubpath() }
    default:
        throw DrawingError.unsupportedElement(el.name)
    }
    return .shape(path: path, transform: transform, paint: p, clip: clip)
}

private func paint(_ el: XMLTree) throws -> Paint {
    var props = el.attributes
    // Editor exports put paint in style; the contracts use attributes, but reading both costs nothing.
    for decl in (el.attributes["style"] ?? "").split(separator: ";") {
        let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2 { props[kv[0]] = kv[1] }
    }
    var p = Paint()
    func number(_ key: String) throws -> CGFloat? {
        guard let s = props[key] else { return nil }
        guard let v = try NumberScanner.numbers(s.replacingOccurrences(of: "px", with: "")).first else {
            throw DrawingError.invalidAttribute(key, s)
        }
        return v
    }
    if let s = props["fill"] {
        guard let v = PaintValue(s) else { throw DrawingError.invalidAttribute("fill", s) }
        p.fill = v
    }
    if let s = props["stroke"] {
        guard let v = PaintValue(s) else { throw DrawingError.invalidAttribute("stroke", s) }
        p.stroke = v
    }
    p.strokeWidth = try number("stroke-width")
    p.miterLimit = try number("stroke-miterlimit")
    p.dashOffset = try number("stroke-dashoffset")
    switch props["stroke-linecap"] {
    case "round": p.lineCap = .round
    case "square": p.lineCap = .square
    case "butt": p.lineCap = .butt
    default: break
    }
    switch props["stroke-linejoin"] {
    case "round": p.lineJoin = .round
    case "bevel": p.lineJoin = .bevel
    case "miter": p.lineJoin = .miter
    default: break
    }
    if let rule = props["fill-rule"] { p.evenOdd = rule == "evenodd" }
    if let dash = props["stroke-dasharray"] {
        p.dash = dash == "none" ? [] : try NumberScanner.numbers(dash)
    }
    return p
}

func parseTransform(_ s: String?) throws -> CGAffineTransform {
    guard let s, !s.isEmpty else { return .identity }
    var result = CGAffineTransform.identity
    let pattern = try NSRegularExpression(pattern: "(matrix|translate|scale|rotate|skewX|skewY)\\s*\\(([^)]*)\\)")
    let ns = s as NSString
    for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: m.range(at: 1))
        let a = try NumberScanner.numbers(ns.substring(with: m.range(at: 2)))
        func arg(_ i: Int, _ fallback: CGFloat = 0) -> CGFloat { i < a.count ? a[i] : fallback }
        var t: CGAffineTransform
        switch name {
        case "matrix":
            guard a.count == 6 else { throw DrawingError.invalidAttribute("transform", s) }
            t = CGAffineTransform(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
        case "translate":
            t = CGAffineTransform(translationX: arg(0), y: arg(1))
        case "scale":
            t = CGAffineTransform(scaleX: arg(0, 1), y: arg(1, arg(0, 1)))
        case "rotate":
            let r = arg(0) * .pi / 180
            let cx = arg(1), cy = arg(2)
            t = CGAffineTransform(translationX: cx, y: cy).rotated(by: r).translatedBy(x: -cx, y: -cy)
        case "skewX":
            t = CGAffineTransform(a: 1, b: 0, c: tan(arg(0) * .pi / 180), d: 1, tx: 0, ty: 0)
        default:
            t = CGAffineTransform(a: 1, b: tan(arg(0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
        }
        // SVG applies the list left to right as nested coordinate systems.
        result = t.concatenating(result)
    }
    return result
}

/// A minimal element tree; namespaced editor elements and attributes are dropped.
final class XMLTree {
    let name: String
    var attributes: [String: String]
    var children: [XMLTree] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) throws -> XMLTree {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = delegate.root else {
            throw DrawingError.invalidXML(parser.parserError?.localizedDescription ?? "empty document")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree?] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard !name.contains(":"), stack.last.map({ $0 != nil }) ?? true else {
                stack.append(nil)
                return
            }
            let el = XMLTree(name: name, attributes: attributes.filter { !$0.key.contains(":") || $0.key.hasPrefix("xlink:") })
            if let parent = stack.last ?? nil { parent.children.append(el) } else if root == nil { root = el }
            stack.append(el)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}

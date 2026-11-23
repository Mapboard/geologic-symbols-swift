import CoreGraphics
import Foundation

enum PathDataError: Error, Equatable {
    case unexpected(Character, offset: Int)
}

/// Parses SVG path data (`d`) into a CGPath: every command, relative forms, implicit repeats, arcs.
func parsePathData(_ d: String) throws -> CGPath {
    var scanner = NumberScanner(Array(d.utf8))
    let path = CGMutablePath()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var lastControl: CGPoint?
    var lastCommand: UInt8 = 0
    var command: UInt8 = 0

    while true {
        scanner.skipSeparators()
        guard let c = scanner.peek() else { break }
        if isCommand(c) {
            command = c
            scanner.advance()
        } else if command == 0 {
            throw PathDataError.unexpected(Character(UnicodeScalar(c)), offset: scanner.index)
        } else if command == UInt8(ascii: "M") {
            command = UInt8(ascii: "L")
        } else if command == UInt8(ascii: "m") {
            command = UInt8(ascii: "l")
        }
        let relative = command >= UInt8(ascii: "a")
        let upper = relative ? command - 32 : command
        func point() throws -> CGPoint {
            let x = try scanner.number(), y = try scanner.number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        switch upper {
        case UInt8(ascii: "M"):
            current = try point()
            start = current
            path.move(to: current)
        case UInt8(ascii: "L"):
            current = try point()
            path.addLine(to: current)
        case UInt8(ascii: "H"):
            let x = try scanner.number()
            current.x = relative ? current.x + x : x
            path.addLine(to: current)
        case UInt8(ascii: "V"):
            let y = try scanner.number()
            current.y = relative ? current.y + y : y
            path.addLine(to: current)
        case UInt8(ascii: "C"):
            let c1 = try point(), c2 = try point(), end = try point()
            path.addCurve(to: end, control1: c1, control2: c2)
            lastControl = c2
            current = end
        case UInt8(ascii: "S"):
            let c1 = reflect(lastControl, if: "CcSs", lastCommand, around: current)
            let c2 = try point(), end = try point()
            path.addCurve(to: end, control1: c1, control2: c2)
            lastControl = c2
            current = end
        case UInt8(ascii: "Q"):
            let c = try point(), end = try point()
            path.addQuadCurve(to: end, control: c)
            lastControl = c
            current = end
        case UInt8(ascii: "T"):
            let c = reflect(lastControl, if: "QqTt", lastCommand, around: current)
            let end = try point()
            path.addQuadCurve(to: end, control: c)
            lastControl = c
            current = end
        case UInt8(ascii: "A"):
            let rx = try scanner.number(), ry = try scanner.number(), rotation = try scanner.number()
            let large = try scanner.flag(), sweep = try scanner.flag()
            let end = try point()
            addArc(to: path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
            current = end
        case UInt8(ascii: "Z"):
            path.closeSubpath()
            current = start
        default:
            throw PathDataError.unexpected(Character(UnicodeScalar(command)), offset: scanner.index)
        }
        if !"CcSsQqTt".utf8.contains(command) { lastControl = nil }
        lastCommand = command
    }
    return path
}

private func isCommand(_ c: UInt8) -> Bool {
    "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
}

private func reflect(_ control: CGPoint?, if commands: String, _ last: UInt8, around p: CGPoint) -> CGPoint {
    guard let control, commands.utf8.contains(last) else { return p }
    return CGPoint(x: 2 * p.x - control.x, y: 2 * p.y - control.y)
}

/// SVG endpoint arc to cubic Béziers (SVG 1.1 implementation notes, F.6).
private func addArc(
    to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
    rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool
) {
    var rx = abs(rxIn), ry = abs(ryIn)
    if p0 == p1 { return }
    if rx == 0 || ry == 0 {
        path.addLine(to: p1)
        return
    }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
        rx *= sqrt(lambda)
        ry *= sqrt(lambda)
    }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var coef = sqrt(max(0, num / den))
    if large == sweep { coef = -coef }
    let cx1 = coef * rx * y1 / ry
    let cy1 = -coef * ry * x1 / rx
    let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
    let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }

    let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    let step = delta / CGFloat(segments)
    let t = 4 / 3 * tan(step / 4)
    var theta = theta1
    func point(_ a: CGFloat) -> CGPoint {
        CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
    }
    func derivative(_ a: CGFloat) -> CGPoint {
        CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
    }
    for i in 0..<segments {
        let next = theta + step
        let a = point(theta), b = point(next)
        let da = derivative(theta), db = derivative(next)
        let end = i == segments - 1 ? p1 : b
        path.addCurve(to: end,
                      control1: CGPoint(x: a.x + t * da.x, y: a.y + t * da.y),
                      control2: CGPoint(x: b.x - t * db.x, y: b.y - t * db.y))
        theta = next
    }
}

/// Reads SVG numbers, which may run together (`1.5.5`, `-1-2`, `1e-3`).
struct NumberScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
    mutating func advance() { index += 1 }

    mutating func skipSeparators() {
        while let c = peek(), c == 32 || c == 9 || c == 10 || c == 13 || c == UInt8(ascii: ",") { index += 1 }
    }

    mutating func flag() throws -> Bool {
        skipSeparators()
        guard let c = peek(), c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else {
            throw PathDataError.unexpected(peek().map { Character(UnicodeScalar($0)) } ?? " ", offset: index)
        }
        index += 1
        return c == UInt8(ascii: "1")
    }

    mutating func number() throws -> CGFloat {
        skipSeparators()
        let begin = index
        if let c = peek(), c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { index += 1 }
        var digits = false, dot = false
        while let c = peek() {
            if c >= 48 && c <= 57 {
                digits = true
            } else if c == UInt8(ascii: ".") && !dot {
                dot = true
            } else {
                break
            }
            index += 1
        }
        if digits, let c = peek(), c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
            var j = index + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
            if j < bytes.count, bytes[j] >= 48 && bytes[j] <= 57 {
                index = j
                while let d = peek(), d >= 48 && d <= 57 { index += 1 }
            }
        }
        guard digits, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else {
            throw PathDataError.unexpected(peek().map { Character(UnicodeScalar($0)) } ?? " ", offset: begin)
        }
        return CGFloat(value)
    }

    /// Every number in the string, for `points`, `viewBox` and transform arguments.
    static func numbers(_ s: String) throws -> [CGFloat] {
        var scanner = NumberScanner(Array(s.utf8))
        var out: [CGFloat] = []
        while true {
            scanner.skipSeparators()
            if scanner.peek() == nil { return out }
            out.append(try scanner.number())
        }
    }
}

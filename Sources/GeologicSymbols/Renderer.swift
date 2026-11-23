import CoreGraphics
import Foundation

/// How to draw a symbol: the native counterpart of `recolorPatternSVG` in the web column-symbols package.
public struct SymbolStyle: @unchecked Sendable {
    /// Colour for `currentColor`; nil uses the item's ink (black for patterns).
    public var ink: CGColor?
    /// Fills the tile first, and is the colour `#ffffff` knock-outs take; nil leaves the tile transparent
    /// and knock-outs clear.
    public var background: CGColor?
    /// Multiplies stroke widths; above 1, filled shapes also gain an outline of `(weight - 1) * fillLineWidth`.
    public var weight: CGFloat
    public var fillLineWidth: CGFloat

    public init(ink: CGColor? = nil, background: CGColor? = nil, weight: CGFloat = 1, fillLineWidth: CGFloat = 1) {
        self.ink = ink
        self.background = background
        self.weight = weight
        self.fillLineWidth = fillLineWidth
    }
}

public enum SymbolRenderer {
    /// Draws into `rect` of a y-down context. Patterns fill the rect; glyphs keep their aspect, centred.
    /// `recolorable` false draws colours as authored (multicolor glyphs, full-colour patterns).
    /// `fillsBackground` false leaves the rect unfilled while knock-outs still take the background, for glyphs
    /// drawn over other artwork (decorations along a line).
    public static func draw(
        _ drawing: Drawing, in context: CGContext, rect: CGRect, style: SymbolStyle,
        recolorable: Bool = true, preserveAspect: Bool = false, fillsBackground: Bool = true
    ) {
        let vb = drawing.viewBox
        guard vb.width > 0, vb.height > 0 else { return }
        var sx = rect.width / vb.width, sy = rect.height / vb.height
        var origin = rect.origin
        if preserveAspect {
            let s = min(sx, sy)
            origin.x += (rect.width - vb.width * s) / 2
            origin.y += (rect.height - vb.height * s) / 2
            sx = s
            sy = s
        }
        context.saveGState()
        if fillsBackground, let background = style.background {
            context.setFillColor(background)
            context.fill(rect)
        }
        context.clip(to: rect)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: sx, y: sy)
        context.translateBy(x: -vb.minX, y: -vb.minY)
        let painter = Painter(
            context: context, clips: drawing.clips, style: style, recolorable: recolorable,
            ink: style.ink ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        )
        painter.draw(drawing.root, parent: .initial)
        context.restoreGState()
    }

    /// A bitmap of `size` points at `scale` pixels per point, y-down artwork drawn upright.
    public static func image(
        _ drawing: Drawing, size: CGSize, scale: CGFloat = 2, style: SymbolStyle,
        recolorable: Bool = true, preserveAspect: Bool = false
    ) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        draw(drawing, in: context, rect: CGRect(x: 0, y: 0, width: w, height: h), style: style,
             recolorable: recolorable, preserveAspect: preserveAspect)
        return context.makeImage()
    }
}

private struct Painter {
    let context: CGContext
    let clips: [String: CGPath]
    let style: SymbolStyle
    let recolorable: Bool
    let ink: CGColor

    func draw(_ node: Node, parent: Paint) {
        switch node {
        case .group(let transform, let paint, let clip, let children):
            context.saveGState()
            context.concatenate(transform)
            applyClip(clip)
            let resolved = paint.inheriting(parent)
            for child in children { draw(child, parent: resolved) }
            context.restoreGState()
        case .shape(let path, let transform, let paint, let clip):
            context.saveGState()
            context.concatenate(transform)
            applyClip(clip)
            fillAndStroke(path, paint.inheriting(parent))
            context.restoreGState()
        }
    }

    func applyClip(_ id: String?) {
        guard let id, let path = clips[id] else { return }
        context.addPath(path)
        context.clip()
    }

    /// The colour a paint value takes, or nil for none; knock-outs set `clear`.
    func color(_ value: PaintValue?) -> (CGColor, clear: Bool)? {
        switch value {
        case .none?, nil:
            return nil
        case .currentColor?:
            return (ink, false)
        case .rgb(let r, let g, let b)?:
            if recolorable && value == .white {
                if let background = style.background { return (background, false) }
                return (CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), true)
            }
            return (CGColor(srgbRed: r, green: g, blue: b, alpha: 1), false)
        }
    }

    func fillAndStroke(_ path: CGPath, _ p: Paint) {
        let fill = color(p.fill)
        var stroke = color(p.stroke)
        var width = (p.strokeWidth ?? 1) * style.weight
        var join = p.lineJoin ?? .miter
        var miter = p.miterLimit ?? 4
        if stroke == nil, let fill, style.weight > 1 {
            stroke = fill
            width = (style.weight - 1) * style.fillLineWidth
            join = .miter
            miter = 2
        }
        if let (c, clear) = fill {
            context.saveGState()
            context.setBlendMode(clear ? .clear : .normal)
            context.setFillColor(c)
            context.addPath(path)
            context.fillPath(using: (p.evenOdd ?? false) ? .evenOdd : .winding)
            context.restoreGState()
        }
        if let (c, clear) = stroke, width > 0 {
            context.saveGState()
            context.setBlendMode(clear ? .clear : .normal)
            context.setStrokeColor(c)
            context.setLineWidth(width)
            context.setLineCap(p.lineCap ?? .butt)
            context.setLineJoin(join)
            context.setMiterLimit(miter)
            if let dash = p.dash, !dash.isEmpty, dash.contains(where: { $0 > 0 }) {
                let pattern = dash.count % 2 == 1 ? dash + dash : dash
                context.setLineDash(phase: p.dashOffset ?? 0, lengths: pattern)
            }
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
    }
}

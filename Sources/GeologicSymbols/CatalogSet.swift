import CoreGraphics
import Foundation

/// A symbol id taken apart (spec/addressing.md):
/// `collection [":" group] ":" item ("+" modifier)* ["/" part] (":" style)*`.
public struct SymbolID: Hashable, Sendable, CustomStringConvertible {
    public var prefix: String
    public var group: String?
    public var name: String
    public var modifiers: [String]
    public var part: String?
    public var style: [String]

    /// `prefix:[group:]name`, the form applications store.
    public var key: String {
        if let group { return "\(prefix):\(group):\(name)" }
        return "\(prefix):\(name)"
    }

    public var description: String {
        var s = key + modifiers.map { "+\($0)" }.joined()
        if let part { s += "/\(part)" }
        return s + style.map { ":\($0)" }.joined()
    }

    /// Parses an id; `grouped` says whether the collection's ids carry a group segment.
    public init?(_ id: String, grouped: Bool) {
        let segments = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let itemIndex = grouped ? 2 : 1
        guard segments.count > itemIndex, !segments[0].isEmpty else { return nil }
        prefix = segments[0]
        group = grouped ? segments[1] : nil
        var item = Substring(segments[itemIndex])
        if let slash = item.firstIndex(of: "/") {
            part = String(item[item.index(after: slash)...])
            item = item[..<slash]
        }
        let pieces = item.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let first = pieces.first, !first.isEmpty else { return nil }
        name = first
        modifiers = Array(pieces.dropFirst())
        style = Array(segments.dropFirst(itemIndex + 1))
    }
}

/// What an id resolves to.
public struct ResolvedSymbol: @unchecked Sendable {
    /// Canonical id of the item that answers, `prefix:[group:]name`.
    public var id: String
    /// The id asked for, when it differs (an alias or an overridden id).
    public var requested: String?
    public var modifiers: [String]
    public var part: String?
    public var style: [String]
    public var item: SymbolItem
    public var bundle: CollectionBundle
    /// Set when an item in another collection replaced the one requested.
    public var overrides: String?

    public var kind: SymbolKind { item.kind }
    public var collection: SymbolCollection { bundle.collection }
}

public enum CatalogSetError: Error, CustomStringConvertible {
    case duplicatePrefix(String)
    case overriddenTwice(String)

    public var description: String {
        switch self {
        case .duplicatePrefix(let p):
            return "collection prefix \"\(p)\" appears twice in a catalog set without distinct parts"
        case .overriddenTwice(let id): return "\"\(id)\" is overridden twice"
        }
    }
}

/// An ordered list of collections with resolution across them; mirrors the web core package's `CatalogSet`.
public final class CatalogSet: @unchecked Sendable {
    public let bundles: [CollectionBundle]
    private var owners: [String: [String: CollectionBundle]] = [:]
    private var keys: [String: [String: SymbolItem]] = [:]
    private var grouped: Set<String> = []
    private var overridden: [String: (CollectionBundle, SymbolItem)] = [:]

    public init(_ bundles: [CollectionBundle]) throws {
        self.bundles = bundles
        var parts: [String: Set<String?>] = [:]
        for b in bundles {
            let seen = parts[b.prefix, default: []]
            // Bundles may share a prefix only as distinct named parts of one collection.
            guard seen.isEmpty || (b.collection.part != nil && !seen.contains(b.collection.part) && !seen.contains(nil))
            else { throw CatalogSetError.duplicatePrefix(b.prefix) }
            parts[b.prefix, default: []].insert(b.collection.part)
            if b.collection.items.contains(where: { $0.group != nil }) { grouped.insert(b.prefix) }
            for item in b.collection.items {
                keys[b.prefix, default: [:]][item.key] = item
                owners[b.prefix, default: [:]][item.key] = b
            }
        }
        for b in bundles {
            for item in b.collection.items {
                for alias in item.aliases ?? [] where keys[b.prefix]?[alias] == nil {
                    keys[b.prefix]?[alias] = item
                    owners[b.prefix]?[alias] = b
                }
            }
        }
        for b in bundles {
            for item in b.collection.items {
                guard let target = item.overrides else { continue }
                guard overridden[target] == nil else { throw CatalogSetError.overriddenTwice(target) }
                overridden[target] = (b, item)
            }
        }
    }

    /// Loads every `.geolsym` bundle in a directory, in name order.
    public convenience init(directory: URL) throws {
        try self.init(CollectionBundle.bundles(in: directory))
    }

    /// The first bundle with this prefix; a collection in parts has several (`bundles`).
    public func bundle(_ prefix: String) -> CollectionBundle? { bundles.first { $0.prefix == prefix } }

    /// Parses an id the way its collection expects (with or without a group segment).
    public func parse(_ id: String) -> SymbolID? {
        guard let prefix = id.split(separator: ":", maxSplits: 1).first.map(String.init) else { return nil }
        return SymbolID(id, grouped: grouped.contains(prefix))
    }

    /// Answers an id, following aliases and overrides.
    public func resolve(_ id: String) -> ResolvedSymbol? {
        guard let parsed = parse(id) else { return nil }
        let localKey = parsed.group.map { "\($0):\(parsed.name)" } ?? parsed.name
        let item = keys[parsed.prefix]?[localKey]
        let canonical = item.map { "\(parsed.prefix):\($0.key)" } ?? parsed.key
        if let (b, replacement) = overridden[canonical] {
            return ResolvedSymbol(
                id: "\(b.prefix):\(replacement.key)", requested: parsed.key, modifiers: parsed.modifiers,
                part: parsed.part, style: parsed.style, item: replacement, bundle: b, overrides: canonical
            )
        }
        guard let item, let b = owners[parsed.prefix]?[localKey] else { return nil }
        return ResolvedSymbol(
            id: canonical, requested: canonical == parsed.key ? nil : parsed.key, modifiers: parsed.modifiers,
            part: parsed.part, style: parsed.style, item: item, bundle: b, overrides: nil
        )
    }

    /// Finds an item by a stored label (title, name, labels or aliases), ignoring case.
    public func find(_ label: String, prefix: String? = nil, kind: SymbolKind? = nil) -> ResolvedSymbol? {
        let target = fold(label)
        let candidates = prefix.map { p in bundles.filter { $0.prefix == p } } ?? bundles
        for b in candidates {
            for item in b.collection.items {
                if let kind, item.kind != kind { continue }
                let names = [item.title, item.name] + (item.labels ?? []).map(\.value) + (item.aliases ?? [])
                if names.contains(where: { fold($0) == target }) { return resolve("\(b.prefix):\(item.key)") }
            }
        }
        return nil
    }

    /// Every item the set answers for, overridden items replaced by their overrides.
    public func list(kind: SymbolKind? = nil, prefix: String? = nil) -> [ResolvedSymbol] {
        var seen = Set<String>()
        var out: [ResolvedSymbol] = []
        for b in bundles where prefix == nil || b.prefix == prefix {
            for item in b.collection.items where kind == nil || item.kind == kind {
                guard let r = resolve("\(b.prefix):\(item.key)"), seen.insert(r.id).inserted else { continue }
                out.append(r)
            }
        }
        return out
    }

    // MARK: Images

    /// One tile of a fill pattern, `tileScale` times its nominal size, at `scale` pixels per point.
    public func patternImage(_ id: String, style: SymbolStyle = SymbolStyle(), tileScale: CGFloat = 1,
                             scale: CGFloat = 2) -> CGImage? {
        guard let r = resolve(id), r.kind == .pattern, let drawing = try? r.bundle.drawing(for: r.item) else {
            return nil
        }
        let nominal = r.item.pattern?.tile?.points ?? drawing.viewBox.size
        let size = CGSize(width: nominal.width * tileScale, height: nominal.height * tileScale)
        return SymbolRenderer.image(drawing, size: size, scale: scale, style: style, recolorable: r.item.recolorable)
    }

    /// A glyph at `size` points (default its nominal size, else 16 pt across), drawn in the style's ink or
    /// the item's own.
    public func glyphImage(_ id: String, size: CGSize? = nil, style: SymbolStyle = SymbolStyle(),
                           scale: CGFloat = 2) -> CGImage? {
        guard let r = resolve(id), r.kind == .glyph, let drawing = try? r.bundle.drawing(for: r.item) else {
            return nil
        }
        var style = style
        if style.ink == nil { style.ink = r.item.defaultInk }
        let vb = drawing.viewBox.size
        let fallback = CGSize(width: 16, height: 16 * vb.height / max(vb.width, 0.0001))
        return SymbolRenderer.image(
            drawing, size: size ?? r.item.glyph?.size?.points ?? fallback, scale: scale, style: style,
            recolorable: r.item.recolorable, preserveAspect: true
        )
    }
}

extension CatalogSet {
    /// The image a map asks for by id when a style names one it lacks (Mapbox `onStyleImageMissing`,
    /// MapLibre `styleimagemissing`): `fgdc:627:#3a5:#fff` draws pattern 627 in ink #3a5 on #fff.
    public func styleImage(_ id: String, scale: CGFloat = 2) -> CGImage? {
        guard let r = resolve(id) else { return nil }
        let args = StyleArguments(r.style)
        switch r.kind {
        case .pattern:
            return patternImage(id, style: args.style, tileScale: args.scale, scale: scale)
        case .glyph:
            let size = r.item.glyph?.size?.points.applying(CGAffineTransform(scaleX: args.scale, y: args.scale))
            return glyphImage(id, size: size, style: args.style, scale: scale)
        default:
            return nil
        }
    }
}

/// Style arguments after an id (spec/addressing.md): colours in order ink then background, and
/// `weight=` and `scale=` multipliers. Others (FGDC's `option=`) are ignored here.
public struct StyleArguments: Sendable {
    public var style = SymbolStyle()
    public var scale: CGFloat = 1

    public init(_ args: [String]) {
        var colors: [CGColor] = []
        for arg in args {
            if arg.hasPrefix("#"), let rgb = parseHex(arg) {
                colors.append(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            } else if arg.hasPrefix("weight="), let w = Double(arg.dropFirst(7)) {
                style.weight = CGFloat(w)
            } else if arg.hasPrefix("scale="), let s = Double(arg.dropFirst(6)) {
                scale = CGFloat(s)
            }
        }
        style.ink = colors.first
        style.background = colors.count > 1 ? colors[1] : nil
    }
}

extension SymbolItem {
    /// The item's ink as a colour: `glyph.ink`, else black.
    public var defaultInk: CGColor {
        let rgb = glyph?.ink.flatMap(parseHex) ?? (0, 0, 0)
        return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

private func fold(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

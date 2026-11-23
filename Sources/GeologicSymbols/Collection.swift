import CoreGraphics
import Foundation

/// A symbol collection's manifest: `collection.json` in a bundle (spec/collections.md).
public struct SymbolCollection: Codable, Sendable {
    /// Bundle layout version; nil for a compiled source collection.
    public var bundleFormat: Int?
    public var prefix: String
    public var title: String
    public var description: String?
    public var homepage: String?
    public var authority: String
    public var version: String
    public var license: String?
    public var authors: [String]?
    public var provenance: Provenance?
    public var items: [SymbolItem]

    enum CodingKeys: String, CodingKey {
        case bundleFormat = "bundle_format"
        case prefix, title, description, homepage, authority, version, license, authors, provenance, items
    }
}

public struct SymbolKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let pattern = SymbolKind(rawValue: "pattern")
    public static let glyph = SymbolKind(rawValue: "glyph")
    public static let line = SymbolKind(rawValue: "line")
}

public struct SymbolItem: Codable, Sendable {
    public var name: String
    public var kind: SymbolKind
    public var title: String
    public var description: String?
    public var category: String?
    public var labels: [Label]?
    public var aliases: [String]?
    public var references: [String: LooseString]?
    public var overrides: String?
    public var group: String?
    public var from: String?
    public var related: [String]?
    public var broader: String?
    public var file: String?
    public var license: String?
    public var provenance: Provenance?
    public var pattern: PatternProperties?
    public var glyph: GlyphProperties?
    /// Inline artwork, as compiled source collections carry it.
    public var viewBox: String?
    public var body: String?

    /// The item's key within its collection: `group:name` in a grouped collection.
    public var key: String {
        if let group { return "\(group):\(name)" }
        return name
    }
}

/// A label, plain (English) or language-tagged.
public struct Label: Codable, Hashable, Sendable {
    public var value: String
    public var lang: String?

    public init(value: String, lang: String? = nil) {
        self.value = value
        self.lang = lang
    }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            value = s
            lang = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(String.self, forKey: .value)
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
    }
}

/// A string that YAML may have typed as a number (`fgdc: 627`).
public struct LooseString: Codable, Hashable, Sendable, CustomStringConvertible {
    public var description: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            description = s
        } else if let i = try? c.decode(Int.self) {
            description = String(i)
        } else {
            description = String(try c.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public struct Provenance: Codable, Sendable {
    public var source: String?
    public var path: String?
    public var note: String?
}

public struct SymbolSize: Codable, Sendable {
    public var width: Double
    public var height: Double
    public var units: String

    /// Size in points: 1 pt, 1/96 in per px (CSS), 72/25.4 per mm.
    public var points: CGSize {
        let k: Double
        switch units {
        case "mm": k = 72 / 25.4
        case "px": k = 0.75
        default: k = 1
        }
        return CGSize(width: width * k, height: height * k)
    }
}

public struct PatternProperties: Codable, Sendable {
    public var tile: SymbolSize?
    public var recolorable: Bool?
}

public struct GlyphProperties: Codable, Sendable {
    public var anchor: [Double]?
    public var size: SymbolSize?
    /// `mono`, `two-tone` or `multicolor`.
    public var color: String?
    /// Default colour for currentColor, `#rrggbb`; black when absent.
    public var ink: String?
    public var rotates: Bool?
    public var parameters: [SymbolParameter]?
}

public struct SymbolParameter: Codable, Sendable {
    public var name: String
    public var position: Int?
    public var kind: String
}

extension SymbolItem {
    /// Whether ink and background apply: `#ffffff` is then a knock-out and `currentColor` the ink.
    var recolorable: Bool {
        if kind == .pattern { return pattern?.recolorable ?? true }
        return (glyph?.color ?? "mono") != "multicolor"
    }
}

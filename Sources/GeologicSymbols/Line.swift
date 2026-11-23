import Foundation

/// A line item's drawing: layers along the line, in order (spec/collections.md, "The line kind").
/// Lengths are millimetres at map scale.
public struct LineProperties: Codable, Sendable {
    /// Default colour, `#rrggbb`; black when absent.
    public var ink: String?
    /// Decorations go on one side: right of travel, or left when the feature's side is -1.
    public var oriented: Bool?
    public var locations: [LineLocation]?
    public var fgdc: FGDCNumbering?
    public var layers: [LineLayer]
    /// Drawing options by number; each replaces `layers`.
    public var options: [String: LineOption]?
    /// Replaces the collection's location rule.
    public var dash: LocationDash?
    /// Replaces the collection's query mark.
    public var questionable: PlaceLayer?

    /// The layers for an FGDC drawing option (1 is `layers`).
    public func layers(option: Int) -> [LineLayer] {
        options?[String(option)]?.layers ?? layers
    }
}

public enum LineLocation: String, Codable, Sendable, CaseIterable {
    case accurate, approximate, inferred, concealed
}

public struct FGDCNumbering: Codable, Sendable {
    public var family: String
    /// Where each drawing option's block of eight numbers starts.
    public var start: [String: Int]
}

public struct LineOption: Codable, Sendable {
    public var layers: [LineLayer]
}

public enum LineLayer: Codable, Sendable {
    case stroke(StrokeLayer)
    case place(PlaceLayer)
    case label(LabelLayer)

    enum CodingKeys: String, CodingKey { case stroke, place, label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(StrokeLayer.self, forKey: .stroke) {
            self = .stroke(s)
        } else if let p = try c.decodeIfPresent(PlaceLayer.self, forKey: .place) {
            self = .place(p)
        } else if let l = try c.decodeIfPresent(LabelLayer.self, forKey: .label) {
            self = .label(l)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown line layer"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stroke(let s): try c.encode(s, forKey: .stroke)
        case .place(let p): try c.encode(p, forKey: .place)
        case .label(let l): try c.encode(l, forKey: .label)
        }
    }
}

public struct StrokeLayer: Codable, Sendable {
    public var width: Double
    /// Perpendicular, positive toward the decorated side.
    public var offset: Double?
    /// `butt`, `round` (default) or `square`.
    public var cap: String?
    /// `miter`, `round` (default) or `bevel`.
    public var join: String?
    public var dash: StrokeDash?
    /// `line` (default) or `#ffffff`, a knock-out in the background colour.
    public var ink: String?
}

public enum StrokeDash: Codable, Sendable {
    /// From the location rule.
    case location
    /// Solid in every state.
    case none
    /// Fixed lengths in mm.
    case lengths([Double])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = s == "none" ? .none : .location
        } else {
            self = .lengths(try c.decode([Double].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .location: try c.encode("location")
        case .none: try c.encode("none")
        case .lengths(let l): try c.encode(l)
        }
    }
}

public struct PlaceLayer: Codable, Sendable {
    /// An item key in the line's collection (`line-decorations:sawtooth`) or a full id.
    public var glyph: String
    /// Part name in image ids; default the glyph's name.
    public var part: String?
    /// `interval` (default), `middle`, `start`, `end` or `ends`.
    public var at: String?
    public var interval: Double?
    /// The glyph's longest side; default its nominal size.
    public var size: Double?
    /// Perpendicular, positive toward the decorated side.
    public var offset: Double?
    /// `along` (default) or `upright`.
    public var rotate: String?
    /// States it is drawn in; default all but concealed.
    public var locations: [LineLocation]?

    public var partName: String { part ?? String(glyph.split(separator: ":").last ?? Substring(glyph)) }
}

public struct LabelLayer: Codable, Sendable {
    public var text: LabelText
    public var interval: Double?
    public var size: Double?
    public var offset: Double?
}

public struct LabelText: Codable, Sendable {
    /// The feature property holding the text.
    public var property: String?
    public var fallback: String?

    enum CodingKeys: String, CodingKey {
        case property
        case fallback = "default"
    }
}

/// The location rule: dash per state in stroke widths; accurate is solid unless given.
public struct LocationDash: Codable, Sendable {
    public var accurate: [Double]?
    public var approximate: [Double]?
    public var inferred: [Double]?
    public var concealed: [Double]?

    public func lengths(_ location: LineLocation) -> [Double]? {
        switch location {
        case .accurate: return accurate
        case .approximate: return approximate
        case .inferred: return inferred
        case .concealed: return concealed
        }
    }
}

public struct LineDefaults: Codable, Sendable {
    public var dash: LocationDash?
    public var questionable: PlaceLayer?
}

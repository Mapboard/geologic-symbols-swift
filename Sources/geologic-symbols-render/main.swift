// Renders every item of a bundle to PNG, to compare against other renderers. Lines are drawn along the wavy
// sample in four forms: accurate, inferred and questionable, concealed, and decorated on the left.
//   geologic-symbols-render <bundle> <out-dir> [pixels]
import CoreGraphics
import Foundation
import GeologicSymbols
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: geologic-symbols-render <bundle> <out-dir> [pixels]\n".utf8))
    exit(2)
}
let bundle = try CollectionBundle(contentsOf: URL(fileURLWithPath: args[1]))
let out = URL(fileURLWithPath: args[2])
let pixels = CGFloat(args.count > 3 ? Double(args[3]) ?? 128 : 128)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let catalog = try CatalogSet([bundle])
var failures = 0

func write(_ image: CGImage, _ name: String) throws {
    let url = out.appendingPathComponent("\(name.replacingOccurrences(of: ":", with: "_")).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for item in bundle.collection.items where item.kind == .line {
    let id = "\(bundle.prefix):\(item.key)"
    let locations = item.line?.locations ?? [.accurate]
    var forms: [(String, Int)] = [("", 1), ("+questionable", 1), ("", -1)]
    for location in [LineLocation.inferred, .concealed] where locations.contains(location) {
        forms.insert(("+\(location.rawValue)" + (location == .inferred ? "+questionable" : ""), 1), at: forms.count - 1)
    }
    forms.removeAll { $0.0 == "+questionable" && locations.contains(.inferred) }
    for (n, (modifiers, side)) in forms.enumerated() {
        guard let image = catalog.lineImage(id + modifiers, size: CGSize(width: pixels * 2, height: pixels / 2),
                                            side: side, style: LineStyle(background: white, unitsPerMM: 3.2), scale: 1)
        else {
            failures += 1
            print("\(id)\(modifiers): not drawn")
            continue
        }
        try write(image, "\(item.key)-\(n)")
    }
}

for item in bundle.collection.items where item.kind == .pattern || item.kind == .glyph {
    do {
        let drawing = try bundle.drawing(for: item)
        // Square and stretched, as `rsvg-convert` draws a viewBox with preserveAspectRatio="none".
        let style = SymbolStyle(ink: item.kind == .glyph ? item.defaultInk : nil, background: white)
        let recolorable = item.kind == .pattern ? (item.pattern?.recolorable ?? true) : item.glyph?.color != "multicolor"
        guard let image = SymbolRenderer.image(
            drawing, size: CGSize(width: pixels, height: pixels), scale: 1, style: style, recolorable: recolorable
        ) else { throw CocoaError(.fileWriteUnknown) }
        let url = out.appendingPathComponent("\(item.key.replacingOccurrences(of: ":", with: "_")).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    } catch {
        failures += 1
        print("\(item.key): \(error)")
    }
}
print("\(bundle.prefix): \(bundle.collection.items.count - failures) rendered, \(failures) failed")
exit(failures == 0 ? 0 : 1)

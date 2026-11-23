// Renders every item of a bundle to PNG, to compare against other renderers.
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
var failures = 0
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

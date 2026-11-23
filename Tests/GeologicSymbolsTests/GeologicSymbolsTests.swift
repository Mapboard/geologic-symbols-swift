import CoreGraphics
import XCTest
@testable import GeologicSymbols

final class GeologicSymbolsTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "geolsym"))
    }

    func catalog() throws -> CatalogSet {
        try CatalogSet([CollectionBundle(contentsOf: fixture("demo")), CollectionBundle(contentsOf: fixture("ext"))])
    }

    // MARK: Collections and ids

    func testDecodesBundle() throws {
        let b = try CollectionBundle(contentsOf: fixture("demo"))
        XCTAssertEqual(b.prefix, "demo")
        XCTAssertEqual(b.collection.bundleFormat, 1)
        let cross = try XCTUnwrap(b.collection.items.first { $0.name == "cross" })
        XCTAssertEqual(cross.references?["fgdc"]?.description, "627")
        XCTAssertEqual(cross.glyph?.size?.points.width ?? 0, 5 * 72 / 25.4, accuracy: 1e-9)
        let stripes = try XCTUnwrap(b.collection.items.first)
        XCTAssertEqual(stripes.labels?.last, Label(value: "Rayas", lang: "es"))
    }

    func testRejectsNewerBundleFormat() throws {
        XCTAssertThrowsError(try CollectionBundle(contentsOf: fixture("future")))
    }

    func testParsesIds() throws {
        let flat = try XCTUnwrap(SymbolID("fgdc:2.15.1:K", grouped: false))
        XCTAssertEqual(flat.name, "2.15.1")
        XCTAssertEqual(flat.style, ["K"])
        let full = try XCTUnwrap(SymbolID("geo:faults:detachment-fault+inferred+questionable/hachure:#231f20", grouped: true))
        XCTAssertEqual(full.group, "faults")
        XCTAssertEqual(full.name, "detachment-fault")
        XCTAssertEqual(full.modifiers, ["inferred", "questionable"])
        XCTAssertEqual(full.part, "hachure")
        XCTAssertEqual(full.style, ["#231f20"])
        XCTAssertEqual(full.key, "geo:faults:detachment-fault")
        XCTAssertEqual(full.description, "geo:faults:detachment-fault+inferred+questionable/hachure:#231f20")
        XCTAssertNil(SymbolID("geo:faults", grouped: true))
    }

    func testResolvesAliasesGroupsAndOverrides() throws {
        let set = try catalog()
        let cross = try XCTUnwrap(set.resolve("demo:cross:K"))
        XCTAssertEqual(cross.id, "demo:cross")
        XCTAssertEqual(cross.style, ["K"])
        XCTAssertNil(cross.requested)

        let thrust = try XCTUnwrap(set.resolve("ext:faults:thrust+inferred/teeth"))
        XCTAssertEqual(thrust.id, "ext:faults:thrust")
        XCTAssertEqual(thrust.modifiers, ["inferred"])
        XCTAssertEqual(thrust.part, "teeth")

        let replaced = try XCTUnwrap(set.resolve("demo:old-stripes"))
        XCTAssertEqual(replaced.id, "ext:fills:stripes")
        XCTAssertEqual(replaced.overrides, "demo:stripes")
        XCTAssertEqual(replaced.requested, "demo:old-stripes")

        XCTAssertNil(set.resolve("demo:missing"))
        XCTAssertNil(set.resolve("nowhere:cross"))
    }

    func testFindsLabels() throws {
        let set = try catalog()
        XCTAssertEqual(set.find("  STRIPED ")?.requested, "demo:stripes")
        XCTAssertEqual(set.find("rayas", prefix: "demo")?.item.name, "stripes")
        XCTAssertNil(set.find("Cross", kind: .pattern))
        XCTAssertEqual(set.find("Cross", kind: .glyph)?.id, "demo:cross")
    }

    func testListReplacesOverriddenItems() throws {
        let ids = try catalog().list().map(\.id)
        XCTAssertEqual(ids.filter { $0 == "ext:fills:stripes" }.count, 1)
        XCTAssertFalse(ids.contains("demo:stripes"))
    }

    func testRejectsDuplicatePrefixes() throws {
        let b = try CollectionBundle(contentsOf: fixture("demo"))
        XCTAssertThrowsError(try CatalogSet([b, b]))
    }

    // MARK: Path data

    func testPathDataForms() throws {
        // Implicit lineto after moveto, numbers run together, arcs, smooth curves.
        let implicit = try parsePathData("m 0.94,117.7 5.5,0.01")
        XCTAssertEqual(implicit.boundingBox.width, 5.5, accuracy: 1e-6)
        let packed = try parsePathData("M0-1.5.5.5L-1-2")
        XCTAssertEqual(packed.currentPoint, CGPoint(x: -1, y: -2))
        let circle = try parsePathData("M1 5a4 4 0 1 1 8 0a4 4 0 1 1-8 0z")
        XCTAssertEqual(circle.boundingBoxOfPath.minY, 1, accuracy: 1e-3)
        XCTAssertEqual(circle.boundingBoxOfPath.maxY, 9, accuracy: 1e-3)
        let flags = try parsePathData("M0 0a5 5 0 0110 0")
        XCTAssertEqual(flags.currentPoint.x, 10, accuracy: 1e-9)
        XCTAssertEqual(try parsePathData("M1e1 2E-1h.5").currentPoint, CGPoint(x: 10.5, y: 0.2))
        XCTAssertThrowsError(try parsePathData("10 10"))
    }

    func testTransformOrder() throws {
        let t = try parseTransform("translate(10 0) scale(2)")
        XCTAssertEqual(CGPoint(x: 1, y: 1).applying(t), CGPoint(x: 12, y: 2))
        let r = try parseTransform("rotate(90 5 5)")
        let p = CGPoint(x: 10, y: 5).applying(r)
        XCTAssertEqual(p.x, 5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 10, accuracy: 1e-9)
    }

    // MARK: Rendering

    func testPatternInkAndBackground() throws {
        let set = try catalog()
        let style = SymbolStyle(ink: color(0, 0, 1), background: color(1, 1, 0))
        // The override is a glyph, so asking for a pattern gets nothing.
        XCTAssertNil(set.patternImage("demo:stripes", style: style))
        let plain = try CatalogSet([CollectionBundle(contentsOf: fixture("demo"))])
        let tile = try XCTUnwrap(plain.patternImage("demo:stripes", style: style, tileScale: 2, scale: 1))
        XCTAssertEqual(tile.width, 20)
        XCTAssertEqual(pixel(tile, 2, 10), [0, 0, 255, 255])
        XCTAssertEqual(pixel(tile, 17, 10), [255, 255, 0, 255])
    }

    func testKnockOutTakesBackgroundOrClears() throws {
        let set = try CatalogSet([CollectionBundle(contentsOf: fixture("demo"))])
        let withBackground = try XCTUnwrap(set.patternImage("demo:lenses", style: SymbolStyle(background: color(0, 1, 0)), scale: 4))
        XCTAssertEqual(pixel(withBackground, 20, 20), [0, 255, 0, 255])
        XCTAssertEqual(pixel(withBackground, 2, 2), [0, 0, 0, 255])
        let clear = try XCTUnwrap(set.patternImage("demo:lenses", scale: 4))
        XCTAssertEqual(pixel(clear, 20, 20)[3], 0)
        XCTAssertEqual(pixel(clear, 2, 2), [0, 0, 0, 255])
    }

    func testFullColourPatternKeepsColours() throws {
        let set = try CatalogSet([CollectionBundle(contentsOf: fixture("demo"))])
        let tile = try XCTUnwrap(set.patternImage("demo:flag", style: SymbolStyle(ink: color(0, 1, 0)), scale: 2))
        XCTAssertEqual(pixel(tile, 3, 10), [255, 0, 0, 255])
        XCTAssertEqual(pixel(tile, 15, 10), [0, 0, 255, 255])
    }

    func testGlyphDefaultInkSizeAndClip() throws {
        let set = try catalog()
        let cross = try XCTUnwrap(set.glyphImage("demo:cross", scale: 1))
        XCTAssertEqual(cross.width, Int((5 * 72 / 25.4).rounded()))
        let mid = cross.width / 2
        XCTAssertEqual(pixel(cross, mid, mid), [0xec, 0x00, 0x8c, 255])
        XCTAssertEqual(pixel(cross, 1, 1)[3], 0)

        let boxed = try XCTUnwrap(set.glyphImage("demo:boxed", size: CGSize(width: 10, height: 10), scale: 4))
        XCTAssertEqual(pixel(boxed, 10, 20), [0, 0, 0, 255])
        XCTAssertEqual(pixel(boxed, 30, 20)[3], 0)
    }

    func testGlyphKeepsAspect() throws {
        let set = try catalog()
        let wide = try XCTUnwrap(set.glyphImage("ext:faults:thrust", size: CGSize(width: 20, height: 10), scale: 1))
        XCTAssertEqual(pixel(wide, 1, 9)[3], 0)
        XCTAssertEqual(pixel(wide, 10, 9), [0, 0, 0, 255])
    }

    func testInlineArtworkAndWeight() throws {
        let set = try catalog()
        let inline = try XCTUnwrap(set.glyphImage("demo:inline", size: CGSize(width: 4, height: 4), scale: 1))
        XCTAssertEqual(pixel(inline, 2, 2), [0, 0, 0, 255])
        let thin = try XCTUnwrap(set.glyphImage("demo:cross", size: CGSize(width: 40, height: 40), scale: 1))
        let heavy = try XCTUnwrap(set.glyphImage("demo:cross", size: CGSize(width: 40, height: 40),
                                                 style: SymbolStyle(weight: 2), scale: 1))
        XCTAssertEqual(pixel(thin, 14, 10)[3], 0)
        XCTAssertEqual(pixel(heavy, 14, 10)[3], 255)
    }

    func testStyleImageArguments() throws {
        let set = try CatalogSet([CollectionBundle(contentsOf: fixture("demo"))])
        let tile = try XCTUnwrap(set.styleImage("demo:stripes:#00f:#ff0:scale=2", scale: 1))
        XCTAssertEqual(tile.width, 20)
        XCTAssertEqual(pixel(tile, 2, 10), [0, 0, 255, 255])
        XCTAssertEqual(pixel(tile, 17, 10), [255, 255, 0, 255])
        let glyph = try XCTUnwrap(set.styleImage("demo:cross", scale: 1))
        XCTAssertEqual(pixel(glyph, glyph.width / 2, glyph.width / 2), [0xec, 0x00, 0x8c, 255])
        XCTAssertNil(set.styleImage("demo:nothing"))
    }

    func testCurvesRender() throws {
        let set = try catalog()
        XCTAssertNotNil(set.glyphImage("demo:curves", size: CGSize(width: 20, height: 20)))
    }

    // MARK: Helpers

    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// RGBA at (x, y) from the top-left, un-premultiplied.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }
}

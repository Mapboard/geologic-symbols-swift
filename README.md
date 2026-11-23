# GeologicSymbols

Geologic map symbology for Apple platforms: reads symbol collections — FGDC fill patterns and point symbols, GMT's
patterns, and collections of your own — and draws them with CoreGraphics at any ink, background, weight and scale.
The Swift counterpart of the `@geologic` web packages, developed alongside the collections in
*geology-visualization-standard*, where this repository is a submodule.

The package is code only. Symbol data comes as **collection bundles**, which an app includes as resources.

## Install

Swift Package Manager, iOS 15 / macOS 12 or later:

```swift
.package(url: "https://github.com/Mapboard/geologic-symbols-swift.git", branch: "main")
```

and depend on the `GeologicSymbols` product.

## Collection bundles

A bundle is a directory, `<prefix>.geolsym/`, holding `collection.json` and one SVG per symbol under `patterns/` and
`glyphs/`. A collection may come in parts, `<prefix>.<part>.geolsym/`, which keep its prefix and are merged by
`CatalogSet`: FGDC is `fgdc.map` (map-unit patterns and point symbols) and `fgdc.column` (lithology patterns).
Build them in geology-visualization-standard, then copy the ones the app needs:

```sh
yarn bundles                    # dist/bundles/*.geolsym, each drawn with this package to check it
```

Add the folder to the app target as a folder reference, so the bundles keep their directory structure, and commit
it: each collection update is then a reviewable diff, pinned to the version of this package that reads it. A
bundle's `bundle_format` is checked on load; one newer than the reader throws `CollectionBundleError.unsupportedFormat`.

Licences are recorded in each `collection.json`, per item where they differ. Check them before shipping: in the
FGDC bundle the fill patterns are CC0, but the point symbols come from a digitisation declared GPL-3.0 (the FGDC
artwork itself is public domain). The GMT bundle is LGPL-3.0-or-later.

## Use

```swift
import GeologicSymbols

let folder = Bundle.main.url(forResource: "Symbols", withExtension: nil)!
let symbols = try CatalogSet(directory: folder)

symbols.resolve("fgdc:607")?.item.title         // "Pattern 607"
symbols.find("Sandstone", kind: .pattern)        // match a stored label

// A pattern tile: ink and background, line weight, size relative to nominal.
let tile = symbols.patternUIImage("fgdc:607", style: SymbolStyle(ink: UIColor.brown.cgColor,
                                                                 background: UIColor.white.cgColor))

// A glyph at its nominal size, in its own ink (FGDC fold symbols are magenta).
let fold = symbols.glyphUIImage("fgdc:5.11.1")
```

### Map styles

Map libraries ask for images they lack by id. `styleImage(_:)` answers ids in the form the web packages use,
`prefix:name[:ink[:background]][:weight=…][:scale=…]` — so a style can name `fgdc:607:#8b5a2b:#fff7e6` and
the tile is drawn on first request. With the Mapbox Maps SDK (v11; a sketch):

```swift
mapView.mapboxMap.onStyleImageMissing.observe { [weak mapView] event in
    guard let mapView, let image = symbols.styleImage(event.imageId, scale: UIScreen.main.scale) else { return }
    try? mapView.mapboxMap.addImage(UIImage(cgImage: image, scale: UIScreen.main.scale, orientation: .up),
                                    id: event.imageId)
}
```

Fill patterns cannot be recoloured on the GPU, so each ink × background combination is its own image. Single-ink
glyphs can be one image drawn white and added with `sdf: true`, then coloured per feature with `icon-color`.

### Lines

Line items (the `geo` collection's faults, folds, contacts, …) are drawn from layers of strokes and glyphs placed
along the line. Modifiers in the id choose the location state and the query mark, and `side` puts decorations left
of travel instead of right (the right-hand rule):

```swift
// A preview for a picker or legend, along a gently bending sample line.
let preview = symbols.lineImage("geo:faults:thrust-fault+inferred", size: CGSize(width: 96, height: 24))

// Along any path, in a y-down context; colour, weight and FGDC's drawing option are style.
symbols.drawLine("geo:folds:anticline+questionable", along: points, in: context, side: -1,
                 style: LineStyle(unitsPerMM: 4))
```

For map styles, each placed glyph is a part image: `geo:faults:thrust-fault/sawtooth:#231f20` from
`styleImage(_:)`, and `…:flip` for the reflected image, which a feature with `side` -1 uses.

## What it draws

Bundles hold artwork restricted to the **pattern and glyph contracts** of the collection format, which is what
lets this package draw without an SVG library: `g`, `path` (every command), `rect`, `circle`, `ellipse`, `line`,
`polyline` and `polygon`; transforms; fill, stroke, width, caps, joins, dashes and fill rule; rectangular clips.
`currentColor` is the ink. `#ffffff` is a knock-out, drawn in the background colour, or cleared when there is no
background. Full-colour patterns and `multicolor` glyphs keep their colours.

Ids follow the collection format's addressing:
`collection [":" group] ":" item ("+" modifier)* ["/" part] (":" style)*`. `CatalogSet` follows aliases and
overrides between collections as the web `CatalogSet` does.

## Development

```sh
swift test                      # use Xcode's toolchain: `xcrun swift test`
swift run geologic-symbols-render <bundle> <out-dir> 128      # every item to PNG, for comparison
```

Test fixtures are small hand-written bundles. Rendering of the published bundles is checked against `rsvg-convert`
from the parent repository.

## License

MIT. Collection bundles carry their own licences.

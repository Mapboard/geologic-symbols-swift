#if canImport(UIKit)
import UIKit

extension CatalogSet {
    /// A pattern tile as a UIImage at the screen's scale, for a map style image or a `UIColor(patternImage:)`.
    public func patternUIImage(_ id: String, style: SymbolStyle = SymbolStyle(), tileScale: CGFloat = 1,
                               scale: CGFloat = UIScreen.main.scale) -> UIImage? {
        patternImage(id, style: style, tileScale: tileScale, scale: scale).map {
            UIImage(cgImage: $0, scale: scale, orientation: .up)
        }
    }

    /// A glyph as a UIImage at the screen's scale. Pass a white ink to use it as an SDF (single-colour) icon.
    public func glyphUIImage(_ id: String, size: CGSize? = nil, style: SymbolStyle = SymbolStyle(),
                             scale: CGFloat = UIScreen.main.scale) -> UIImage? {
        glyphImage(id, size: size, style: style, scale: scale).map {
            UIImage(cgImage: $0, scale: scale, orientation: .up)
        }
    }
}
#endif

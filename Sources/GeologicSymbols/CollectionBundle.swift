import Foundation

public enum CollectionBundleError: Error, CustomStringConvertible {
    case unsupportedFormat(Int)
    case noArtwork(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let v):
            return "bundle_format \(v) is newer than this reader (\(CollectionBundle.supportedFormat)); update GeologicSymbols"
        case .noArtwork(let name): return "\(name) has no artwork"
        }
    }
}

/// A collection and its artwork: a `<prefix>.geolsym` bundle directory, or a compiled `collection.json`
/// with inline artwork. Drawings are parsed on first use and cached.
public final class CollectionBundle: @unchecked Sendable {
    /// The newest `bundle_format` this reader understands.
    public static let supportedFormat = 1
    public static let pathExtension = "geolsym"

    public let collection: SymbolCollection
    public let directory: URL?
    private var drawings: [String: Drawing] = [:]
    private let lock = NSLock()

    public var prefix: String { collection.prefix }

    public init(collection: SymbolCollection, directory: URL? = nil) throws {
        if let format = collection.bundleFormat, format > Self.supportedFormat {
            throw CollectionBundleError.unsupportedFormat(format)
        }
        self.collection = collection
        self.directory = directory
    }

    /// Reads a bundle directory, or a `collection.json` file directly.
    public convenience init(contentsOf url: URL) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let manifest = isDirectory ? url.appendingPathComponent("collection.json") : url
        let collection = try JSONDecoder().decode(SymbolCollection.self, from: Data(contentsOf: manifest))
        try self.init(collection: collection, directory: manifest.deletingLastPathComponent())
    }

    /// Every `.geolsym` bundle in a directory (an app's resource folder), sorted by name.
    public static func bundles(in directory: URL) throws -> [CollectionBundle] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == pathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try CollectionBundle(contentsOf: $0) }
    }

    public func drawing(for item: SymbolItem) throws -> Drawing {
        lock.lock()
        defer { lock.unlock() }
        if let cached = drawings[item.key] { return cached }
        let drawing: Drawing
        if let file = item.file, let directory {
            drawing = try Drawing(svg: Data(contentsOf: directory.appendingPathComponent(file)))
        } else if let viewBox = item.viewBox, let body = item.body {
            drawing = try Drawing(viewBox: viewBox, body: body)
        } else {
            throw CollectionBundleError.noArtwork(item.key)
        }
        drawings[item.key] = drawing
        return drawing
    }
}

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GeologicSymbols",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "GeologicSymbols", targets: ["GeologicSymbols"]),
    ],
    targets: [
        .target(name: "GeologicSymbols"),
        .executableTarget(name: "geologic-symbols-render", dependencies: ["GeologicSymbols"]),
        .testTarget(
            name: "GeologicSymbolsTests",
            dependencies: ["GeologicSymbols"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

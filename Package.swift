// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lamp-bible-core",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "LampCore", targets: ["LampCore"]),
        .library(name: "LampModuleKit", targets: ["LampModuleKit"]),
        // SwiftUI stays out of LampCore: the module CLI and the MCP server link
        // it headlessly and must not pull in a UI framework.
        .library(name: "LampPresentationUI", targets: ["LampPresentationUI"]),
        // Apple Intelligence stays out of LampCore for the same reason: the
        // apps ask the on-device model, the headless tools never do.
        .library(name: "LampIntelligence", targets: ["LampIntelligence"]),
        .executable(name: "lamp-module", targets: ["LampModuleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "6.29.3"),
        // Apple's cmark-gfm wrapper. Core reads Markdown in several
        // places — where the assistant's marks may be placed, what a
        // clear may reach, how a document is drawn — and every reader
        // was written by hand against the cases we happened to meet.
        // Six rounds of review found six ways one of them took in a
        // delimiter belonging to text the writer never selected. The
        // rule behind all of them is CommonMark's, so core reads
        // Markdown with a CommonMark parser.
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "LampModuleKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "LampCore",
            dependencies: [
                "LampModuleKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // The places a map can name (`LampMapPlaces`).
            resources: [.copy("Resources/Maps")]
        ),
        .target(
            name: "LampPresentationUI",
            dependencies: ["LampCore"],
            // A map's land, water and relief (`LampMapShapes`).
            resources: [.copy("Resources/Maps")]
        ),
        .target(
            name: "LampIntelligence",
            dependencies: ["LampCore", "LampModuleKit"]
        ),
        .executableTarget(
            name: "LampModuleCLI",
            dependencies: [
                "LampCore",
                "LampModuleKit",
            ]
        ),
        .testTarget(
            name: "LampModuleKitTests",
            dependencies: [
                "LampModuleKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "LampPresentationUITests",
            dependencies: [
                "LampPresentationUI",
                "LampCore",
            ]
        ),
        .testTarget(
            name: "LampIntelligenceTests",
            dependencies: ["LampIntelligence", "LampCore"]
        ),
        .testTarget(
            name: "LampCoreTests",
            dependencies: [
                "LampCore",
                "LampModuleKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

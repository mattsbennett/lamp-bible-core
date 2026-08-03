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
        .executable(name: "lamp-module", targets: ["LampModuleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "6.29.3"),
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
            ]
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

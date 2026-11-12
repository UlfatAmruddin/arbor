// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Arbor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Arbor", targets: ["Arbor"])],
    dependencies: [
        // In-app updates (FE-259, DEC-028). Exact version: an update changes what checks release signatures.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure Foundation logic: listing, sorting, history, paths, naming, transfers. Fully unit-tested.
        .target(name: "ArborCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // AppKit user interface.
        .executableTarget(
            name: "Arbor",
            dependencies: ["ArborCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("NetFS")]
        ),
        // Release tooling: the update feed of a release (scripts/make-update.sh). Not part of the app.
        .executableTarget(name: "ArborAppcast", dependencies: ["ArborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ArborCoreTests", dependencies: ["ArborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks of the app module that need no window: every feature registers without extension errors.
        .testTarget(name: "ArborTests", dependencies: ["Arbor"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

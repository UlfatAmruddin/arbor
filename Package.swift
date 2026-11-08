// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Arbor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Arbor", targets: ["Arbor"])],
    targets: [
        // Pure Foundation logic: listing, sorting, history, paths, naming, transfers. Fully unit-tested.
        .target(name: "ArborCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // AppKit user interface.
        .executableTarget(
            name: "Arbor",
            dependencies: ["ArborCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Quartz"), .linkedFramework("NetFS")]
        ),
        .testTarget(name: "ArborCoreTests", dependencies: ["ArborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Checks of the app module that need no window: every feature registers without extension errors.
        .testTarget(name: "ArborTests", dependencies: ["Arbor"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

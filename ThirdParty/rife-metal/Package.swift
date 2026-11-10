// swift-tools-version: 5.10
// OpenDuckFrame modification: library-only package for the pinned rife-metal source.
import PackageDescription

let package = Package(
    name: "RifeMetal",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "RifeMetal", targets: ["RifeMetal", "RifeMetalCore"]),
    ],
    targets: [
        .target(
            name: "RifeMetal",
            dependencies: ["RifeMetalCore"],
            resources: [.copy("Resources/rife-v4.25.rmw")]
        ),
        .target(
            name: "RifeMetalCore",
            exclude: ["Shaders"],
            plugins: [.plugin(name: "CompileMetalShaders")]
        ),
        .plugin(
            name: "CompileMetalShaders",
            capability: .buildTool()
        ),
    ]
)

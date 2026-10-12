// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Docksmith",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DocksmithCore", targets: ["DocksmithCore"]),
        .executable(name: "docksmith", targets: ["docksmith"]),
        .executable(name: "DocksmithApp", targets: ["DocksmithApp"]),
    ],
    targets: [
        .target(name: "DocksmithCore"),
        .executableTarget(name: "docksmith", dependencies: ["DocksmithCore"]),
        .executableTarget(name: "DocksmithApp", dependencies: ["DocksmithCore"]),
        .testTarget(name: "DocksmithCoreTests", dependencies: ["DocksmithCore"]),
    ],
    swiftLanguageModes: [.v6]
)

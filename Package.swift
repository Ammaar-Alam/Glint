// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Glint", targets: ["Glint"])],
    targets: [
        .executableTarget(name: "Glint"),
        .testTarget(name: "GlintTests", dependencies: ["Glint"])
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipt",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Clipt", targets: ["Clipt"])],
    targets: [
        .executableTarget(name: "Clipt"),
        .testTarget(name: "CliptTests", dependencies: ["Clipt"])
    ],
    swiftLanguageModes: [.v5]
)

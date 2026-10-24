// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Glint", targets: ["Glint"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "Glint",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            // the app bundle carries Sparkle in Contents/Frameworks
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // the test bundle sits beside Sparkle.framework in the build products
        .testTarget(name: "GlintTests", dependencies: ["Glint"],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])])
    ],
    swiftLanguageModes: [.v5]
)

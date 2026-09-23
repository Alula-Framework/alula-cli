// swift-tools-version: 6.3
import PackageDescription

// The Alula CLI.
//
// `templates/` holds complete, CI-verified projects, and they are embedded in
// this binary rather than read from disk at run time: an installed CLI has no
// repository to read from. `Sources/alula/EmbeddedTemplates.swift` is
// generated from those directories by CI/generate-embedded-templates.sh, and
// CI fails if it has drifted from them.
let package = Package(
    name: "alula-cli",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "alula", targets: ["alula"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0")
    ],
    targets: [
        .executableTarget(
            name: "alula",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "alulaTests", dependencies: ["alula"]),
    ]
)

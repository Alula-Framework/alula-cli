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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        // For `alula explain`: the diagnostic pages, from the one source of
        // truth the build's diagnostics link to. No traits, so this resolves
        // Alula's lean graph and builds only the dependency-free
        // AlulaDiagnostics.
        .package(url: "https://github.com/Alula-Framework/alula.git", from: "0.51.0", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "alula",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AlulaDiagnostics", package: "alula"),
            ]
        ),
        .testTarget(name: "alulaTests", dependencies: ["alula"]),
    ]
)

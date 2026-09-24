// swift-tools-version: 6.3
import PackageDescription

// An Alula application, at its smallest: configuration, dependency injection,
// an HTTP server, and the operational endpoints. Nothing else — no database,
// no real-time layer, no cache.
//
// Two package dependencies carry all of it. `alula` is the framework and the
// layers above it; `alula-data` is persistence and caching, and is absent
// here because this tier does not persist anything yet.
let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        // `traits:` names what you want from alula, and nothing else is
        // resolved. "Web" is HTTP, WebSockets, Channels and Presence; add
        // "Security" for authentication. Naming neither gives you just the
        // core: configuration, composition, and the service lifecycle.
        .package(url: "https://github.com/Alula-Framework/alula.git", from: "0.44.0", traits: ["Web"])
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaWeb", package: "alula"),
                // Choosing a transport is choosing a module. This one wraps
                // HummingbirdCore; any conforming transport is a peer.
                .product(name: "AlulaTransport", package: "alula"),
                .product(name: "AlulaActuator", package: "alula"),
            ],
            // Scans this target for @Component/@Controller/@Service and
            // generates the composition root (`alulaComposeModules`) at build time. It also checks
            // every @ConfigValue key without a default against alula.yaml,
            // so a missing key is a compile error rather than a 3am page.
            plugins: [
                .plugin(name: "AlulaRegistrationPlugin", package: "alula")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaWeb", package: "alula"),
                .product(name: "AlulaWebTesting", package: "alula"),
            ]
        ),
    ]
)

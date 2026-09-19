// swift-tools-version: 6.3
import PackageDescription

// A Flight application, at its smallest: configuration, dependency injection,
// an HTTP server, and the operational endpoints. Nothing else — no database,
// no real-time layer, no cache.
//
// Two package dependencies carry all of it. `flight` is the framework and the
// layers above it; `flight-data` is persistence and caching, and is absent
// here because this tier does not persist anything yet.
let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        // `traits:` names what you want from flight, and nothing else is
        // resolved. "Web" is HTTP, WebSockets, Channels and Presence; add
        // "Security" for authentication. Naming neither gives you just the
        // core: configuration, composition, and the service lifecycle.
        .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.21.2", traits: ["Web"])
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightWeb", package: "flight"),
                // Choosing a transport is choosing a module. This one wraps
                // HummingbirdCore; any conforming transport is a peer.
                .product(name: "FlightTransport", package: "flight"),
                .product(name: "FlightActuator", package: "flight"),
            ],
            // Scans this target for @Component/@Controller/@Service and
            // generates the composition root (`flightComposeModules`) at build time. It also checks
            // every @ConfigValue key without a default against flight.yaml,
            // so a missing key is a compile error rather than a 3am page.
            plugins: [
                .plugin(name: "FlightRegistrationPlugin", package: "flight")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightWeb", package: "flight"),
                .product(name: "FlightWebTesting", package: "flight"),
            ]
        ),
    ]
)

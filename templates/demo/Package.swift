// swift-tools-version: 6.3
import PackageDescription

// The Flight demo: one application exercising the whole ecosystem.
//
// Two package dependencies, not eight. `flight` carries the framework and the
// layers on top of it; `flight-data` carries persistence and caching, with the
// Postgres driver requested by trait. Everything below is a product of one of
// those two.
let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        // "defaults" keeps the Web trait on; "Security" adds the resource
        // server. Naming any trait means "default" must be named too.
        .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.7.0", traits: ["Security"]),
        .package(url: "https://github.com/Flight-Framework/flight-data.git", from: "0.2.0", traits: ["Postgres"]),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightWeb", package: "flight"),
                .product(name: "FlightTransport", package: "flight"),
                .product(name: "FlightActuator", package: "flight"),
                .product(name: "FlightScheduler", package: "flight"),
                .product(name: "FlightSecurityCore", package: "flight"),
                .product(name: "FlightPubSub", package: "flight"),
                .product(name: "FlightChannels", package: "flight"),
                .product(name: "FlightChannelsProtocol", package: "flight"),
                .product(name: "FlightPresence", package: "flight"),
                .product(name: "FlightDataPostgres", package: "flight-data"),
                .product(name: "FlightMigrate", package: "flight-data"),
                .product(name: "FlightSchedulerPostgres", package: "flight-data"),
                .product(name: "FlightCache", package: "flight-data"),
            ],
            plugins: [
                .plugin(name: "FlightRegistrationPlugin", package: "flight")
            ]
        ),

        // Migration files live in their own target so FlightMigratePlugin can
        // scan them and generate the _allMigrations() registry at build time.
        // The app target does NOT depend on this — migrations never run at boot.
        .target(
            name: "Migrations",
            dependencies: [.product(name: "FlightMigrate", package: "flight-data")],
            plugins: [.plugin(name: "FlightMigratePlugin", package: "flight-data")]
        ),

        .executableTarget(
            name: "migrate",
            dependencies: [
                "Migrations",
                .product(name: "FlightMigrateCLI", package: "flight-data"),
            ]
        ),

        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightWeb", package: "flight"),
                .product(name: "FlightWebTesting", package: "flight"),
                .product(name: "FlightChannels", package: "flight"),
                .product(name: "FlightChannelsTesting", package: "flight"),
                .product(name: "FlightChannelsClient", package: "flight"),
                .product(name: "FlightPresence", package: "flight"),
                .product(name: "FlightPresenceClient", package: "flight"),
                .product(name: "FlightPubSubTesting", package: "flight"),
                .product(name: "FlightDataPostgres", package: "flight-data"),
                .product(name: "FlightCache", package: "flight-data"),
            ]
        ),
    ]
)

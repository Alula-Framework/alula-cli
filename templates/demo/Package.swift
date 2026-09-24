// swift-tools-version: 6.3
import PackageDescription

// The Alula demo: one application exercising the whole ecosystem.
//
// Two package dependencies, not eight. `alula` carries the framework and the
// layers on top of it; `alula-data` carries persistence and caching, with the
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
        .package(url: "https://github.com/Alula-Framework/alula.git", from: "0.45.0", traits: ["Security"]),
        .package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.15.0", traits: ["Postgres"]),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaWeb", package: "alula"),
                .product(name: "AlulaTransport", package: "alula"),
                .product(name: "AlulaActuator", package: "alula"),
                .product(name: "AlulaScheduler", package: "alula"),
                .product(name: "AlulaQueue", package: "alula"),
                .product(name: "AlulaMail", package: "alula"),
                .product(name: "AlulaOpenAPI", package: "alula"),
                .product(name: "AlulaQueuePostgres", package: "alula-data"),
                .product(name: "AlulaSecurityCore", package: "alula"),
                .product(name: "AlulaPubSub", package: "alula"),
                .product(name: "AlulaRateLimit", package: "alula"),
                .product(name: "AlulaChannels", package: "alula"),
                .product(name: "AlulaChannelsProtocol", package: "alula"),
                .product(name: "AlulaPresence", package: "alula"),
                .product(name: "AlulaDataPostgres", package: "alula-data"),
                .product(name: "AlulaMigrate", package: "alula-data"),
                .product(name: "AlulaSchedulerPostgres", package: "alula-data"),
                .product(name: "AlulaCache", package: "alula-data"),
            ],
            plugins: [
                .plugin(name: "AlulaRegistrationPlugin", package: "alula")
            ]
        ),

        // Migration files live in their own target so AlulaMigratePlugin can
        // scan them and generate the _allMigrations() registry at build time.
        // The app target does NOT depend on this — migrations never run at boot.
        .target(
            name: "Migrations",
            dependencies: [.product(name: "AlulaMigrate", package: "alula-data")],
            plugins: [.plugin(name: "AlulaMigratePlugin", package: "alula-data")]
        ),

        .executableTarget(
            name: "migrate",
            dependencies: [
                "Migrations",
                .product(name: "AlulaMigrateCLI", package: "alula-data"),
            ]
        ),

        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaWeb", package: "alula"),
                .product(name: "AlulaWebTesting", package: "alula"),
                .product(name: "AlulaSessionsTesting", package: "alula"),
                .product(name: "AlulaRateLimitTesting", package: "alula"),
                .product(name: "AlulaQueue", package: "alula"),
                .product(name: "AlulaQueueTesting", package: "alula"),
                .product(name: "AlulaMail", package: "alula"),
                .product(name: "AlulaMailTesting", package: "alula"),
                .product(name: "AlulaChannels", package: "alula"),
                .product(name: "AlulaChannelsTesting", package: "alula"),
                .product(name: "AlulaChannelsClient", package: "alula"),
                .product(name: "AlulaPresence", package: "alula"),
                .product(name: "AlulaPresenceClient", package: "alula"),
                .product(name: "AlulaPubSubTesting", package: "alula"),
                .product(name: "AlulaDataPostgres", package: "alula-data"),
                .product(name: "AlulaCache", package: "alula-data"),
            ]
        ),
    ]
)

// swift-tools-version: 6.3
import PackageDescription

// A Flight application with a database: everything the skeleton has, plus
// entities, migrations, a repository, and CRUD routes over Postgres.
//
// `flight-data` arrives with `traits: ["Postgres"]`. Traits are how a package
// carries drivers without imposing them: naming Postgres resolves PostgresNIO
// and Hangar, and naming no trait at all would resolve neither — you would
// still get the in-memory cache and the data protocols.
let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.20.0", traits: ["Web"]),
        .package(url: "https://github.com/Flight-Framework/flight-data.git", from: "0.6.0", traits: ["Postgres"]),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightWeb", package: "flight"),
                .product(name: "FlightTransport", package: "flight"),
                .product(name: "FlightActuator", package: "flight"),
                .product(name: "FlightDataPostgres", package: "flight-data"),
            ],
            plugins: [
                .plugin(name: "FlightRegistrationPlugin", package: "flight")
            ]
        ),

        // Migrations live in their own target so the migrate plugin can scan
        // them and generate the `_allMigrations()` registry at build time.
        // The app target deliberately does NOT depend on this: migrations are
        // something you run, not something your server does at boot.
        .target(
            name: "Migrations",
            dependencies: [.product(name: "FlightMigrate", package: "flight-data")],
            plugins: [.plugin(name: "FlightMigratePlugin", package: "flight-data")]
        ),

        // `swift run migrate status | up | down | create`.
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
                .product(name: "FlightDataPostgres", package: "flight-data"),
            ]
        ),
    ]
)

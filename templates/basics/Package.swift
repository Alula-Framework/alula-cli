// swift-tools-version: 6.3
import PackageDescription

// An Alula application with a database: everything the skeleton has, plus
// entities, migrations, a repository, and CRUD routes over Postgres.
//
// `alula-data` arrives with `traits: ["Postgres"]`. Traits are how a package
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
        .package(url: "https://github.com/Alula-Framework/alula.git", from: "0.39.0", traits: ["Web"]),
        .package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.13.0", traits: ["Postgres"]),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaWeb", package: "alula"),
                .product(name: "AlulaTransport", package: "alula"),
                .product(name: "AlulaActuator", package: "alula"),
                .product(name: "AlulaDataPostgres", package: "alula-data"),
            ],
            plugins: [
                .plugin(name: "AlulaRegistrationPlugin", package: "alula")
            ]
        ),

        // Migrations live in their own target so the migrate plugin can scan
        // them and generate the `_allMigrations()` registry at build time.
        // The app target deliberately does NOT depend on this: migrations are
        // something you run, not something your server does at boot.
        .target(
            name: "Migrations",
            dependencies: [.product(name: "AlulaMigrate", package: "alula-data")],
            plugins: [.plugin(name: "AlulaMigratePlugin", package: "alula-data")]
        ),

        // `swift run migrate status | up | down | create`.
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
                .product(name: "AlulaDataPostgres", package: "alula-data"),
            ]
        ),
    ]
)

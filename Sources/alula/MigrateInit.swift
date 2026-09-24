import Foundation

/// Adds the migration targets to a project that has none.
///
/// This is the step a project skips by starting from the skeleton template:
/// migrations need a `Migrations` target for the build plugin to scan and a
/// `migrate` executable to run them. Adding them by hand means editing the
/// manifest in three places, which is exactly the mechanical work a CLI
/// should do.
///
/// The pieces are taken from the `basics` template, so what this writes is
/// what CI already builds and tests.
struct MigrateInit {
    let project: Project

    func run() throws {
        guard !project.hasMigrateExecutable else {
            print("\(project.root.lastPathComponent) already has a migrate target — nothing to do.")
            return
        }
        guard let basics = EmbeddedTemplates.files["basics"] else {
            throw CLIError.unknownTier("basics", available: EmbeddedTemplates.tiers)
        }

        var written: [String] = []

        // The migrate executable's entry point and an example migration are
        // the same files the basics template ships.
        for path in ["Sources/migrate/Migrate.swift"] {
            guard let contents = basics[path] else { continue }
            let url = project.root.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            written.append(path)
        }

        // Sources/Migrations needs a Swift file or the target has no module
        // for the migrate executable to import — and an empty directory does
        // not make one. This placeholder is not a migration: the discovery
        // plugin only picks up files whose names start with a timestamp.
        //
        // No real migration is seeded, because any schema written here would
        // be a guess at someone else's.
        let placeholder = project.migrationsDirectory.appendingPathComponent("README.swift")
        if !FileManager.default.fileExists(atPath: placeholder.path) {
            try FileManager.default.createDirectory(
                at: project.migrationsDirectory, withIntermediateDirectories: true)
            try Self.placeholder.write(to: placeholder, atomically: true, encoding: .utf8)
            written.append("Sources/Migrations/README.swift")
        }

        try addTargets()
        written.append("Package.swift")

        print("Added migrations to \(project.root.lastPathComponent):")
        for path in written { print("  \(path)") }
        print("")
        print("  alula migrate create CreateUsers")
        print("  ALULA_DATABASE_URL=postgres://… alula migrate")
    }

    /// Inserts the two targets and, if absent, the alula-data dependency.
    ///
    /// Editing a manifest textually is unlovely, but the alternative is
    /// parsing Swift to rewrite it, and this insert is anchored to the
    /// `targets: [` array opener that every manifest has.
    private func addTargets() throws {
        let manifestURL = project.root.appendingPathComponent("Package.swift")
        var manifest = project.manifest

        if !manifest.contains("Alula-Framework/alula-data.git") {
            guard let range = manifest.range(of: "    dependencies: [\n") else {
                throw CLIError.manifestUnrecognised("no dependencies: [ array")
            }
            manifest.insert(
                contentsOf: """
                            .package(url: "https://github.com/Alula-Framework/alula-data.git",
                                     from: "0.14.0", traits: ["Postgres"]),\n
                    """,
                at: range.upperBound)
        }

        guard let range = manifest.range(of: "    targets: [\n") else {
            throw CLIError.manifestUnrecognised("no targets: [ array")
        }
        manifest.insert(contentsOf: Self.targets, at: range.upperBound)
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    private static let placeholder = """
        // Migration files land here as <14-digit-UTC-timestamp>_<TypeName>.swift,
        // written by `alula migrate create <TypeName>`. Files not starting with
        // a timestamp — like this one — are ignored by the discovery plugin.
        //
        // This file exists so the target has a module to build. Deleting it once
        // you have a real migration is fine.

        """

    private static let targets = """
                // Migrations live in their own target so the migrate plugin can
                // scan them and generate the registry at build time. The app
                // target deliberately does not depend on this: migrations are
                // something you run, not something your server does at boot.
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

        """
}

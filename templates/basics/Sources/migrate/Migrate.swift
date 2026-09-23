import AlulaMigrate
import AlulaMigrateCLI
import Migrations

/// The whole migration CLI. `_allMigrations()` is generated at build time
/// from the files in Sources/Migrations.
///
///     ALULA_DATABASE_URL=postgres://… swift run migrate status
@main
struct Migrate: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}

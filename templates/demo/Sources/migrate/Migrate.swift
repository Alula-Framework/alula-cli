import AlulaMigrate
import AlulaMigrateCLI
import Migrations

@main
struct Migrate: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}
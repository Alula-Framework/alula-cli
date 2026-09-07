import FlightMigrate
import Foundation

/// Migrations are ordinary Swift, discovered at build time by their filename
/// timestamp. Applied migrations are checksummed, so editing one that has
/// already run is caught rather than quietly diverging from the database.
struct CreateUsers: Migration {
    // Postgres runs this inside a transaction with its own bookkeeping, so a
    // failure rolls back cleanly. For statements that cannot run in one —
    // CREATE INDEX CONCURRENTLY, ALTER TYPE ... ADD VALUE — opt out:
    //
    //     static let wrapInTransaction = false

    func up(_ schema: SchemaBuilder) {
        // These names must match `@Entity("users")` exactly. Property names
        // map to columns with no case conversion, so a helper that generated
        // `created_at` would silently miss `createdAt` — spelled out instead.
        schema.createTable("users") { t in
            t.uuid("id").primaryKey().default(.generatedUUID)
            t.varchar("name", limit: 30).notNull()
            t.varchar("email", limit: 50).notNull().unique()
            t.timestamptz("createdAt").notNull().default(.now)
            t.timestamptz("updatedAt").notNull().default(.now)
        }
    }

    /// Every migration says how to undo itself, which is what makes
    /// `migrate down` something you can run rather than something you fear.
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}

import FlightMigrate

struct CreateMessages: Migration {
    // Postgres runs this migration inside a transaction together with its
    // bookkeeping, so a failure rolls back cleanly. For statements that cannot
    // run in a transaction (CREATE INDEX CONCURRENTLY, ALTER TYPE ... ADD VALUE):
    //
    //     static let wrapInTransaction = false

    func up(_ schema: SchemaBuilder) {
        schema.createTable("messages") { t in
            t.uuid("id").primaryKey().default(.generatedUUID)
            t.varchar("room", limit: 30).notNull()
            t.varchar("sender", limit: 50).notNull()
            t.text("body").notNull()
            t.timestamptz("sentAt").notNull()
        }
        schema.createIndex(on: "messages", columns: ["room"])
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("messages")
    }
}

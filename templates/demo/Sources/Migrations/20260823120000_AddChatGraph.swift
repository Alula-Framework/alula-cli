import FlightMigrate

/// Turns the flat `messages` table into a small graph, so the demo can show
/// the query shapes a real application actually needs: rooms holding many
/// messages, messages written by a user, threaded replies (a table pointing
/// at *itself*), curated topics reached through a join table, and a plain
/// Postgres array column.
struct AddChatGraph: Migration {

    func up(_ schema: SchemaBuilder) {
        schema.createTable("rooms") { t in
            t.uuid("id").primaryKey().default(.generatedUUID)
            t.varchar("slug", limit: 40).notNull().unique()
            t.varchar("name", limit: 80).notNull()
            t.boolean("archived").notNull().default(.bool(false))
            t.timestamptz("createdAt").notNull().default(.now)
        }

        schema.createTable("topics") { t in
            t.uuid("id").primaryKey().default(.generatedUUID)
            t.varchar("label", limit: 40).notNull().unique()
        }

        // The join table behind @HasMany(through:). Its own key plus a
        // uniqueness constraint on the pair: a message carries a topic once.
        schema.createTable("messageTopics") { t in
            t.uuid("id").primaryKey().default(.generatedUUID)
            t.uuid("messageID").notNull().references("messages", "id", onDelete: .cascade)
            t.uuid("topicID").notNull().references("topics", "id", onDelete: .cascade)
            t.unique(["messageID", "topicID"])
        }

        schema.alterTable("messages") { t in
            // roomID starts nullable so the backfill below can populate it,
            // then gets tightened to NOT NULL.
            t.addColumn("roomID", .uuid)
            t.addColumn("authorID", .uuid)
            // Self-reference: a reply points at the message it answers.
            t.addColumn("parentID", .uuid)
            t.addColumn("mentions", .array(of: .text)).notNull().default(.raw("'{}'"))
            t.addColumn("redacted", .boolean).notNull().default(.bool(false))
        }

        // Backfill. Every message written before this migration belongs to
        // the room named by its old free-text `room` column, and is credited
        // to the user whose name matches `sender` (if any).
        schema.raw(
            """
            INSERT INTO rooms (slug, name)
            SELECT DISTINCT room, room FROM messages
            ON CONFLICT (slug) DO NOTHING
            """)
        schema.raw(
            """
            UPDATE messages SET "roomID" = rooms.id
            FROM rooms WHERE rooms.slug = messages.room
            """)
        schema.raw(
            """
            UPDATE messages SET "authorID" = users.id
            FROM users WHERE users.name = messages.sender
            """)

        schema.alterTable("messages") { t in
            t.setNotNull("roomID")
            t.addForeignKey(
                ["roomID"], references: "rooms",
                onDelete: .cascade, name: "messages_roomID_fkey")
            t.addForeignKey(
                ["authorID"], references: "users",
                onDelete: .setNull, name: "messages_authorID_fkey")
            t.addForeignKey(
                ["parentID"], references: "messages",
                onDelete: .cascade, name: "messages_parentID_fkey")
        }

        // The indexes the demo's analytics endpoints actually lean on.
        schema.createIndex(on: "messages", columns: ["roomID"])
        schema.createIndex(on: "messages", columns: ["parentID"])
        schema.createIndex(on: "messageTopics", columns: ["topicID"])
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("messageTopics")
        schema.dropTable("topics")
        schema.alterTable("messages") { t in
            t.dropColumn("redacted")
            t.dropColumn("mentions")
            t.dropColumn("parentID")
            t.dropColumn("authorID")
            t.dropColumn("roomID")
        }
        schema.dropTable("rooms")
    }
}

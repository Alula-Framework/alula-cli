import Foundation
import AlulaDataPostgres
import AlulaWeb

/// Failures this repository raises on its own behalf. Controllers map these
/// onto HTTP; the repository stays free of any web vocabulary.
enum ChatError: Error, Sendable {
    case noSuchRoom(UUID)
    case upsertReturnedNothing(String)
    case multiStepFailed(step: String, underlying: any Error)
}

// MARK: - Projections
//
// Every shape below is an ordinary Decodable struct. `select(into:)` takes a
// *labeled* tuple; each label becomes the SQL alias and the key the type
// decodes by, so a mismatch between projection and type is a compile-time or
// first-run error rather than a silently-empty field.

/// One row of "how busy is each room" — a GROUP BY with two aggregates.
struct RoomActivity: Codable, Sendable, ResponseEncodable {
    let room: String
    let messages: Int
    let lastSentAt: Date?
}

/// A message flattened across three tables: the message, its room, its author.
struct MessageCard: Codable, Sendable, ResponseEncodable {
    let id: UUID
    let body: String
    let sentAt: Date
    let roomName: String
    /// Null when the message has no registered author — the left join's
    /// right-hand side is optional, and the projection type says so.
    let authorName: String?
}

/// One reply paired with the message it answers — the output of a self-join.
struct ThreadEntry: Codable, Sendable, ResponseEncodable {
    let replyID: UUID
    let replyBody: String
    let replySentAt: Date
    let parentBody: String
}

/// The most recent message in each room, one row per room.
struct RoomHeadline: Codable, Sendable, ResponseEncodable {
    let roomID: UUID
    let body: String
    let sentAt: Date
}

/// Two lines per message, for the streaming export.
struct ExportLine: Codable, Sendable {
    let sentAt: Date
    let sender: String
    let body: String
}

// MARK: - Repository

/// Where the demo actually exercises Hangar. `UserRepository` covers the
/// everyday shapes — fetch one, fetch all, insert, changeset. This one covers
/// what a real application reaches for once the schema stops being flat:
/// associations, joins (two-table, three-table, and a table joined to
/// itself), aggregates, `DISTINCT ON`, set-based writes, upserts, row locks
/// under a serializable transaction, `Multi`, and streaming.
@Repository
struct ChatRepository: RoomStore {
    /// The pool. Every method below leases a connection for exactly its own
    /// work through `withRepo` and gives it back — there is no request-scoped
    /// connection, so "which connection is this query on" is answered by the
    /// bracket you can see rather than by a scope you cannot.
    // alula:hand-registered — PostgresDataModule registers the pool.
    @Inject var pool: PostgresDataSource

    // MARK: Associations

    /// A room with a page of its messages, and for each of those messages its
    /// author and its topics.
    ///
    /// Three levels of association, and still a fixed number of queries: one
    /// for the room, one for the messages, one for the authors, two for the
    /// topics (join table, then topics). Preloads batch — the count does not
    /// grow with the number of rows, which is the entire reason preloading
    /// exists instead of a lazy accessor.
    func room(slug: String, messageLimit: Int = 20) async throws -> Room? {
        try await pool.withRepo { repo in
            try await repo.one(
                Room.where { $0.slug == slug }
                    .preload(\.messages) { messages in
                        messages
                            .where { $0.redacted == false }
                            .order { $0.sentAt.desc() }
                            .limit(messageLimit)
                            .preload(\.author)
                            .preload(\.topics)
                    })
        }
    }

    /// A user together with everything they wrote, newest first.
    ///
    /// The association crosses a *nullable* foreign key: `messages."authorID"`
    /// is NULL for anyone who never registered. Those rows belong to no user
    /// and appear under none.
    func user(id: UUID, historyLimit: Int = 50) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(
                User.where { $0.id == id }
                    .preload(\.authored) { $0.order { $0.sentAt.desc() }.limit(historyLimit) })
        }
    }

    // MARK: Joins

    /// Message + room + author in one statement — a three-table join
    /// projected into a flat card.
    ///
    /// The room join is inner: every message has a room. The author join is a
    /// LEFT join on a nullable key, so a message from someone who never
    /// registered still appears, with a null author name. Which join goes
    /// where is not a stylistic choice — an inner join here would silently
    /// drop those messages.
    func recentCards(limit: Int = 25) async throws -> [MessageCard] {
        try await pool.withRepo { repo in
            try await repo.all(
                ChatMessage.join(Room.self, on: { message, room in message.roomID == room.id })
                    .leftJoin(User.self, on: { message, _, user in message.authorID == user.id })
                    .where { message, room, _ in message.redacted == false && room.archived == false }
                    .order { message, _, _ in message.sentAt.desc() }
                    .limit(limit)
                    .select(into: MessageCard.self) { message, room, user in
                        (
                            id: message.id, body: message.body, sentAt: message.sentAt,
                            roomName: room.name, authorName: user.name
                        )
                    })
        }
    }

    /// Replies paired with the messages they answer — one table joined to
    /// itself.
    ///
    /// `messages` cannot appear twice in a FROM clause under one name, so both
    /// sides are aliased. Each alias hands back its own column set, and every
    /// reference renders qualified: `"reply"."parentID" = "root"."id"`. Without
    /// the aliases this is not a query Hangar will build — it refuses rather
    /// than emitting ambiguous SQL.
    func thread(rootID: UUID) async throws -> [ThreadEntry] {
        try await pool.withRepo { repo in
            let reply = ChatMessage.alias("reply")
            let root = ChatMessage.alias("root")
            return try await repo.all(
                reply.join(root, on: { reply, root in reply.parentID == root.id })
                    .where { _, root in root.id == rootID }
                    .order { reply, _ in reply.sentAt.asc() }
                    .select(into: ThreadEntry.self) { reply, root in
                        (
                            replyID: reply.id, replyBody: reply.body,
                            replySentAt: reply.sentAt, parentBody: root.body
                        )
                    })
        }
    }

    // MARK: Aggregates

    /// Message counts per room, busiest first, quiet rooms filtered out
    /// *after* grouping — which is what HAVING is for.
    func activity(minimumMessages: Int = 1) async throws -> [RoomActivity] {
        try await pool.withRepo { repo in
            try await repo.all(
                ChatMessage.where { $0.redacted == false }
                    .groupBy { $0.room }
                    .having { $0.id.count() >= minimumMessages }
                    .order { $0.room.asc() }
                    .select(into: RoomActivity.self) {
                        (room: $0.room, messages: $0.id.count(), lastSentAt: $0.sentAt.max())
                    })
        }
    }

    /// The newest message in every room — one row per room, no subquery, no
    /// window function.
    ///
    /// `DISTINCT ON (roomID)` keeps the first row per room as the ORDER BY
    /// sees them, so ordering by `roomID` then `sentAt DESC` picks the latest.
    /// Postgres requires the ORDER BY to lead with the DISTINCT ON columns and
    /// rejects the statement if it doesn't — the ordering is load-bearing, not
    /// cosmetic.
    func headlines() async throws -> [RoomHeadline] {
        try await pool.withRepo { repo in
            try await repo.all(
                ChatMessage.all
                    .distinct(on: { $0.roomID })
                    .order { $0.roomID.asc() }
                    .order { $0.sentAt.desc() }
                    .select(into: RoomHeadline.self) {
                        (roomID: $0.roomID, body: $0.body, sentAt: $0.sentAt)
                    })
        }
    }

    // MARK: Set-based writes

    /// Redacts everything one sender wrote in a room, in a single UPDATE.
    ///
    /// The alternative — fetch, mutate, write back one row at a time — is a
    /// query per row and a race with anyone else writing. This is one
    /// statement, and it returns how many rows it touched.
    func redactAll(sender: String, inRoom roomID: UUID) async throws -> Int {
        try await pool.withRepo { repo in
            try await repo.update(
                ChatMessage.where { $0.sender == sender && $0.roomID == roomID }
            ) {
                ($0.redacted.set(to: true), $0.body.set(to: "[redacted]"))
            }
        }
    }

    /// Deletes every message older than a cutoff, in one DELETE. Returns the
    /// number removed.
    func purge(before cutoff: Date) async throws -> Int {
        try await pool.withRepo { repo in
            try await repo.delete(ChatMessage.where { $0.sentAt < cutoff })
        }
    }

    /// Sender names → user ids, in one query rather than one per name.
    ///
    /// `.in(names)` renders `= ANY($1)` with the whole list bound as a single
    /// array parameter, and the pack-based `select` projects a tuple, so the
    /// result decodes straight into a dictionary. A sender who never
    /// registered is simply absent — which is what leaves `authorID` NULL.
    func authorIDs(forNames names: [String]) async throws -> [String: UUID] {
        try await pool.withRepo { repo in
            let pairs = try await repo.all(
                User.where { $0.name.in(names) }.select { ($0.name, $0.id) })
            return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Inserts a batch of messages as one multi-row INSERT ... RETURNING —
    /// one round trip regardless of how many.
    func post(_ messages: [ChatMessage]) async throws -> [ChatMessage] {
        try await pool.withRepo { repo in
            try await repo.insert(messages)
        }
    }

    /// Finds or creates a topic by label, without a read-then-write race.
    ///
    /// Two concurrent callers both see "no such topic" and both insert; one
    /// loses on the unique index. `ON CONFLICT ... DO UPDATE` makes the loser
    /// return the winning row instead of failing.
    func topic(label: String) async throws -> Topic {
        try await pool.withRepo { repo in
            try await Self.upsertTopic(label: label, on: repo)
        }
    }

    /// The upsert both `topic` and `tag` need, taking a repo the caller
    /// already holds.
    ///
    /// `tag` calling `topic(label:)` would lease a *second* connection while
    /// still holding the first — which is how a small pool deadlocks under
    /// load, and how a two-statement unit of work stops being one.
    private static func upsertTopic(label: String, on repo: Repo) async throws -> Topic {
        let created = try await repo.insert(
            Changeset(Topic.self).change(\.label, label),
            onConflict: .doUpdate(target: [\Topic.label], set: [\Topic.label]))
        guard let topic = created else {
            throw ChatError.upsertReturnedNothing(label)
        }
        return topic
    }

    /// Attaches a topic to a message, creating the topic if it is new.
    ///
    /// Both writes are upserts, so tagging the same message twice is a no-op
    /// rather than an error — the join table's `UNIQUE (messageID, topicID)`
    /// is what makes `.doNothing` meaningful.
    func tag(messageID: UUID, label: String) async throws -> Topic {
        try await pool.withRepo { repo in
            let topic = try await Self.upsertTopic(label: label, on: repo)
            _ = try await repo.insert(
                Changeset(MessageTopic.self)
                    .change(\.messageID, messageID)
                    .change(\.topicID, topic.id),
                onConflict: .doNothing(target: [\MessageTopic.messageID, \MessageTopic.topicID]))
            return topic
        }
    }

    // MARK: Transactions

    /// Archives a room and moves its messages elsewhere, atomically and
    /// without losing a concurrent write.
    ///
    /// Three things are doing work here:
    ///
    /// - `lockForUpdate()` takes a row lock on the room, so a second caller
    ///   archiving the same room waits rather than interleaving.
    /// - `.serializable` asks Postgres for the strongest isolation, under
    ///   which a conflicting pair of transactions is aborted rather than
    ///   allowed to produce a state no serial order could.
    /// - `retryingOnSerializationFailure:` catches exactly that abort
    ///   (SQLSTATE 40001, and deadlocks at 40P01) and runs the body again.
    ///   Serializable without a retry is not a working design; the retry is
    ///   the other half of the feature.
    func archive(roomID: UUID, movingMessagesTo destinationID: UUID) async throws -> Int {
        try await pool.withRepo { repo in
            try await repo.transaction(isolation: .serializable, retryingOnSerializationFailure: 3) { tx in
                guard let room = try await tx.one(Room.where { $0.id == roomID }.lockForUpdate()) else {
                    throw ChatError.noSuchRoom(roomID)
                }
                guard let destination = try await tx.one(Room.where { $0.id == destinationID }) else {
                    throw ChatError.noSuchRoom(destinationID)
                }
                let moved = try await tx.update(ChatMessage.where { $0.roomID == room.id }) {
                    ($0.roomID.set(to: destination.id), $0.room.set(to: destination.slug))
                }
                _ = try await tx.update(Room.where { $0.id == room.id }) {
                    $0.archived.set(to: true)
                }
                return moved
            }
        }
    }

    /// Creates a room and its opening message as one named, ordered unit.
    ///
    /// `Multi` is the alternative to a hand-written transaction body when the
    /// steps are data rather than code: each step is named, later steps read
    /// earlier results by key, and a failure reports *which* step failed
    /// instead of unwinding an opaque closure. Everything runs in one
    /// transaction.
    func openRoom(slug: String, name: String, greeting: String) async throws -> Room {
        try await pool.withRepo { repo in
            let roomKey = MultiKey<Room>("room")
            let greetingKey = MultiKey<ChatMessage>("greeting")

            let result = try await repo.run(
                Multi()
                    .insert(
                        roomKey,
                        Changeset(Room.self)
                            .change(\.slug, slug)
                            .change(\.name, name)
                            .change(\.archived, false)
                            .change(\.createdAt, Date()))
                    .insert(greetingKey) { values in
                        let room = try values[roomKey]
                        return Changeset(ChatMessage.self)
                            .change(\.room, room.slug)
                            .change(\.roomID, room.id)
                            .change(\.sender, "system")
                            .change(\.body, greeting)
                            .change(\.mentions, [])
                            .change(\.redacted, false)
                            .change(\.sentAt, Date())
                    })

            switch result {
            case .success(let values):
                return try values[roomKey]
            case .failure(let failure):
                // Which step failed, not just that something did — the reason
                // Multi is worth reaching for over a hand-written transaction.
                throw ChatError.multiStepFailed(step: failure.key, underlying: failure.error)
            }
        }
    }

    // MARK: Streaming

    /// Exports a room's history without holding it all in memory.
    ///
    /// `all` decodes every row into an array first; `stream` decodes one at a
    /// time as they arrive from the server, so a million-row export costs the
    /// same memory as a ten-row one. The stream borrows the connection for the
    /// duration of the closure and is invalid outside it — carrying it out and
    /// iterating later throws rather than reading from a connection some other
    /// query now owns.
    func export(roomID: UUID, into sink: @Sendable (ExportLine) -> Void) async throws -> Int {
        try await pool.withRepo { repo in
            try await repo.stream(
                ChatMessage.where { $0.roomID == roomID }
                    .order { $0.sentAt.asc() }
                    .select(into: ExportLine.self) {
                        (sentAt: $0.sentAt, sender: $0.sender, body: $0.body)
                    }
            ) { rows in
                var count = 0
                for try await line in rows {
                    sink(line)
                    count += 1
                }
                return count
            }
        }
    }

    // MARK: Runtime-sourced filters

    /// Filters from query-string parameters — field names chosen by the
    /// caller, not the code.
    ///
    /// The allowlist on `ChatMessage` is the whole of the trusted surface: a
    /// field not on it throws `unknownFilterField` rather than reaching SQL,
    /// and a value whose shape doesn't match the column's type throws
    /// `invalidFilterValue`. Values are always bound, never interpolated.
    func search(_ filters: [String: DynamicFilterValue], limit: Int = 50) async throws -> [ChatMessage] {
        try await pool.withRepo { repo in
            try await repo.all(
                ChatMessage.where(dynamic: filters)
                    .order { $0.sentAt.desc() }
                    .limit(limit))
        }
    }
}

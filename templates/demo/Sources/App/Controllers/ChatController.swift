import Foundation
import AlulaChannels
import AlulaChannelsProtocol
import AlulaCore
import AlulaWeb
import AlulaDataCore
import AlulaDataPostgres
import AlulaPresence
import AlulaSecurityCore
import Synchronization

// MARK: - Request bodies

struct OpenRoomRequest: Codable {
    let slug: String
    let name: String
    let greeting: String
}

struct PostMessagesRequest: Codable {
    struct Line: Codable {
        let sender: String
        let body: String
        let mentions: [String]?
        /// Set to make this line a reply — the self-reference the thread
        /// endpoint reads back.
        let replyTo: UUID?
    }
    let roomSlug: String
    let lines: [Line]
}

struct ArchiveRoomRequest: Codable {
    let destinationSlug: String
}

struct RedactRequest: Codable {
    let sender: String
    let roomSlug: String
}

/// One person in a room, as `GET /rooms/:slug/who` reports them.
struct Occupant: Codable, Sendable, ResponseEncodable {
    let key: String
    /// How many live connections this identity holds in the room.
    let connections: Int
    let status: String
}

// MARK: - Controller

/// The HTTP surface over `ChatRepository` — one endpoint per query shape, so
/// each Hangar feature is something you can actually curl.
///
/// Handlers here stay thin on purpose: resolve, delegate, translate errors.
/// Everything interesting about the queries is in `ChatRepository`.
@Controller
struct ChatController {

    /// Injected, not resolved. A controller is constructed per request from
    /// the component graph, so what it needs is a property the build wires.
    /// These were `context.resolve` calls in every method — a lookup per
    /// request for values the composition root has held since start-up.
    @Inject var chat: ChatRepository
    @Inject var digests: RoomDigestService

    /// Provided by `AlulaPresenceModule` and `AlulaChannelsModule` rather
    /// than scanned from this target, so they are roots of the graph. The
    /// marker says the scanner is right not to have found them.
    // alula:hand-registered
    @Inject var presence: any Presence
    // alula:hand-registered
    @Inject var broadcaster: ChannelBroadcaster

    // MARK: Associations

    /// `GET /rooms/:slug` — a room with a page of messages, each message's
    /// author, and each message's topics, as one JSON document.
    ///
    /// Unloaded associations serialize as `null`; loaded ones as their value.
    @GetRoute("/rooms/:slug")
    func room(_ context: RequestContext, slug: String) async throws -> Room {
        guard let room = try await chat.room(slug: slug) else {
            throw HTTPError(.notFound, "no room '\(slug)'")
        }
        return room
    }

    /// `GET /users/:id/history` — a user with everything they wrote.
    /// The association crosses a nullable foreign key.
    @GetRoute("/users/:id/history")
    func history(_ context: RequestContext, id: UUID) async throws -> User {
        guard let user = try await chat.user(id: id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        return user
    }

    // MARK: Joins

    /// `GET /messages/recent` — a three-table join, flattened.
    @GetRoute("/messages/recent")
    func recent(_ context: RequestContext) async throws -> [MessageCard] {
        let limit = context.request.queryParam("limit").flatMap(Int.init) ?? 25
        return try await chat.recentCards(limit: limit)
    }

    /// `GET /messages/:id/thread` — `messages` joined to itself under two
    /// aliases, so each reply arrives next to the message it answers.
    @GetRoute("/messages/:id/thread")
    func thread(_ context: RequestContext, id: UUID) async throws -> [ThreadEntry] {
        try await chat.thread(rootID: id)
    }

    // MARK: Aggregates

    /// `GET /activity?min=3` — GROUP BY with HAVING.
    /// Served from the cache when warm — see `RoomDigestService`. Posting a
    /// message evicts it, so the "post then reload" loop stays truthful.
    @GetRoute("/activity")
    func activity(_ context: RequestContext) async throws -> [RoomActivity] {
        let minimum = context.request.queryParam("min").flatMap(Int.init) ?? 1
        return try await digests.activity(minimumMessages: minimum)
    }

    /// `GET /headlines` — `DISTINCT ON`, one row per room.
    @GetRoute("/headlines")
    func headlines(_ context: RequestContext) async throws -> [RoomHeadline] {
        try await digests.headlines()
    }

    // MARK: Runtime-sourced filters

    /// `GET /messages/search?sender=ada&redacted=false` — every query
    /// parameter is checked against the allowlist on `ChatMessage` before it
    /// can affect the SQL. An unlisted field is a 400, not a silent no-op.
    @GetRoute("/messages/search")
    func search(_ context: RequestContext) async throws -> [ChatMessage] {
        var filters: [String: DynamicFilterValue] = [:]
        for item in context.request.queryItems where item.name != "limit" {
            // Query strings are untyped; the allowlist's column types are not.
            // Handing "true" to a Bool column is a mismatch the filter layer
            // rejects, so parse the obvious shapes here.
            switch item.value {
            case "true": filters[item.name] = .bool(true)
            case "false": filters[item.name] = .bool(false)
            default: filters[item.name] = .string(item.value)
            }
        }
        let limit = context.request.queryParam("limit").flatMap(Int.init) ?? 50
        do {
            return try await chat.search(filters, limit: limit)
        } catch let error as HangarError {
            throw HTTPError(.badRequest, "\(error)")
        }
    }

    // MARK: Presence

    /// `GET /rooms/:slug/who` — the room's live occupancy, over plain HTTP.
    ///
    /// Presence is a cluster-wide CRDT, not a per-socket list, so this answers
    /// for the whole cluster even though this node only holds some of those
    /// connections. It exists mostly so presence is observable with `curl`:
    /// the real consumers are WebSocket clients, which get a
    /// `alula:presence_state` on join and `alula:presence_diff`s after.
    @GetRoute("/rooms/:slug/who")
    func who(_ context: RequestContext, slug: String) async throws -> Response {
        let entries = await presence.list(topic: "room:\(slug)")
        return try .json(
            entries.map { entry in
                // One identity can be present many times — three browser tabs
                // are one key with three metas. Collapsing that to a bare list
                // of names would lose the distinction the data structure
                // exists to keep, so the count travels with the name.
                Occupant(
                    key: entry.key,
                    connections: entry.metas.count,
                    status: entry.metas.compactMap { $0.payload["status"] }.first ?? "online")
            })
    }

    // MARK: Writes

    /// `POST /rooms` — room and opening message as one named `Multi`.
    ///
    /// The unit of work is a `Multi`: steps decided before they run, named,
    /// and executed in one transaction that Hangar opens. There is no
    /// ambient coordinator to bind and nothing outside this call that could
    /// be nesting a transaction around it — the boundary is the closure you
    /// can see. `POST /chatUser` on `UserController` is the other shape,
    /// where the transaction lives inside the repository method.
    @PostRoute("/rooms")
    func openRoom(_ context: RequestContext, body: OpenRoomRequest) async throws -> Response {
        do {
            let room = try await chat.openRoom(
                slug: body.slug, name: body.name, greeting: body.greeting)
            return try .json(room, status: .created)
        } catch let error as ChatError {
            throw error.asHTTPError
        }
    }

    /// `POST /messages` — a batch of messages as one multi-row INSERT.
    @PostRoute("/messages")
    func post(_ context: RequestContext, body: PostMessagesRequest) async throws -> Response {
        guard let room = try await chat.room(slug: body.roomSlug, messageLimit: 0) else {
            throw HTTPError(.notFound, "no room '\(body.roomSlug)'")
        }
        // One query for every distinct sender, not one per line.
        let authors = try await chat.authorIDs(forNames: body.lines.map(\.sender))
        let now = Date()
        let messages = body.lines.map { line in
            ChatMessage(
                id: UUID(), room: room.slug, roomID: room.id, sender: line.sender,
                body: line.body, authorID: authors[line.sender], parentID: line.replyTo,
                mentions: line.mentions ?? [], sentAt: now)
        }
        let stored = try await chat.post(messages)

        // The REST and WebSocket paths write to the same table, so they must
        // fan out to the same subscribers. Anything holding a
        // `ChannelBroadcaster` can broadcast — a handler, a background job,
        // another node — and PubSub delivers it. Without this, a message
        // posted over HTTP would be invisible to everyone currently watching
        // the room over a socket until they reloaded.
        for message in stored {
            await broadcaster.broadcast(
                topic: "room:\(message.room)",
                event: "new_msg",
                payload: RoomChannel.wire(message))
        }
        // The digests are derived from this table; a write makes them stale.
        await digests.messagesChanged()

        return try .json(stored, status: .created)
    }

    /// `POST /topics/:label` — find-or-create without a read-then-write race.
    @PostRoute("/topics/:label")
    func topic(_ context: RequestContext, label: String) async throws -> Topic {
        return try await chat.topic(label: label)
    }

    /// `POST /messages/:id/topics/:label` — tag a message, creating the
    /// topic on first use. Preloading `\.topics` afterwards reads it back
    /// through the join table.
    @PostRoute("/messages/:id/topics/:label")
    func tag(_ context: RequestContext, id: UUID, label: String) async throws -> Topic {
        try await chat.tag(messageID: id, label: label)
    }

    /// `POST /rooms/:slug/archive` — row lock inside a serializable
    /// transaction, retried on a serialization failure.
    @PostRoute("/rooms/:slug/archive")
    func archive(_ context: RequestContext, slug: String, body: ArchiveRoomRequest) async throws -> Response {
        guard let source = try await chat.room(slug: slug, messageLimit: 0),
            let destination = try await chat.room(slug: body.destinationSlug, messageLimit: 0)
        else {
            throw HTTPError(.notFound, "both rooms must exist")
        }
        do {
            let moved = try await chat.archive(
                roomID: source.id, movingMessagesTo: destination.id)
            return try .json(["moved": moved])
        } catch let error as ChatError {
            throw error.asHTTPError
        }
    }

    /// `POST /messages/redact` — one UPDATE over every matching row.
    ///
    /// Redaction is moderation, so it needs a role rather than merely a
    /// logged-in user. `requireRole` is the handler-level guard: 401 with no
    /// principal, 403 with the wrong one. The alternative — registering
    /// `requireAuthentication` as middleware — protects *every* route, which
    /// is the wrong shape for an app whose reads are public.
    ///
    ///     curl -XPOST localhost:8080/messages/redact \
    ///          -H 'Authorization: Bearer demo:ada:moderator' ...
    @PostRoute("/messages/redact")
    func redact(_ context: RequestContext, body: RedactRequest) async throws -> Response {
        try context.requireRole("moderator")
        guard let room = try await chat.room(slug: body.roomSlug, messageLimit: 0) else {
            throw HTTPError(.notFound, "no room '\(body.roomSlug)'")
        }
        let redacted = try await chat.redactAll(sender: body.sender, inRoom: room.id)
        return try .json(["redacted": redacted])
    }

    /// `DELETE /messages?before=<ISO8601>` — one DELETE over every matching
    /// row, returning how many went.
    @DeleteRoute("/messages")
    func purge(_ context: RequestContext) async throws -> Response {
        try context.requireRole("moderator")
        guard let raw = context.request.queryParam("before"),
            let cutoff = try? Date(raw, strategy: .iso8601)
        else {
            throw HTTPError(.badRequest, "before must be an ISO 8601 timestamp")
        }
        let purged = try await chat.purge(before: cutoff)
        await digests.messagesChanged()
        return try .json(["purged": purged])
    }

    // MARK: Streaming

    /// `GET /rooms/:slug/export` — the room's history as line-delimited text.
    ///
    /// Rows decode one at a time off the connection rather than landing in an
    /// array first, so the *decode* cost is flat no matter how long the room's
    /// history is. The response body is still assembled in memory here:
    /// handing the row stream straight to `Response.streaming` would need a
    /// connection that outlives the request scope, which is a different piece
    /// of plumbing than the one this endpoint is demonstrating.
    @GetRoute("/rooms/:slug/export")
    func export(_ context: RequestContext, slug: String) async throws -> Response {
        guard let room = try await chat.room(slug: slug, messageLimit: 0) else {
            throw HTTPError(.notFound, "no room '\(slug)'")
        }
        let lines = Mutex<[String]>([])
        let count = try await chat.export(roomID: room.id) { line in
            lines.withLock {
                $0.append("\(line.sentAt.formatted(.iso8601))\t\(line.sender)\t\(line.body)")
            }
        }
        context.logger.info("exported \(count) messages from \(slug)")
        return .text(lines.withLock { $0.joined(separator: "\n") })
    }
}

extension ChatError {
    /// Repository failures translated at the edge, which is the only layer
    /// that should know about status codes.
    ///
    /// A duplicate slug arrives as a unique violation from inside the
    /// `Multi`'s failed step. That is a conflict the caller can fix, not a
    /// server fault, so it is a 409 — and Hangar's typed `DatabaseError`
    /// tells the two apart without parsing an error message.
    var asHTTPError: HTTPError {
        switch self {
        case .noSuchRoom(let id):
            return HTTPError(.notFound, "no room \(id)")
        case .upsertReturnedNothing(let label):
            return HTTPError(.internalServerError, "upsert returned no row for '\(label)'")
        case .multiStepFailed(let step, let underlying):
            if let database = underlying as? DatabaseError, database.isUniqueViolation {
                return HTTPError(.conflict, "step '\(step)': that value already exists")
            }
            return HTTPError(.internalServerError, "step '\(step)' failed")
        }
    }
}

import AlulaChannels
import AlulaChannelsProtocol
import AlulaCore
import AlulaPresence
import AlulaWeb
import Foundation

/// The live half of the chat room: `ChatController` is its history, this is
/// its present tense.
///
/// One registration serves every room — the pattern is `room:*`, and Channels
/// creates one instance per (socket, topic), so `topic` identifies which room
/// this instance is holding.
///
/// Three layers meet here and each keeps its own job:
///
/// - **Channels** owns the per-connection protocol: join, events, replies.
/// - **PubSub** does the fan-out, so a broadcast reaches subscribers on every
///   node without this code knowing whether there is one node or twenty.
/// - **Presence** answers "who is in this room", CRDT-merged across the
///   cluster. Nothing here ever *removes* a presence: tracking is bound to
///   the socket's membership, so every teardown path — client leave, dropped
///   transport, heartbeat timeout, shutdown — untracks structurally.
struct RoomChannel: Channel {
    let broadcaster: ChannelBroadcaster
    let presence: any Presence
    let chat: any RoomStore
    let digests: any DigestInvalidating

    /// The join is the authorization gate, and the identity it gates on was
    /// established during the HTTP upgrade — before the WebSocket existed.
    /// By the time a frame can arrive, the question is already settled.
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        guard let principal = socket.principal else { return .reject(.unauthenticated) }
        guard let slug = Self.roomSlug(from: topic) else {
            return .reject(JoinRejection("malformed_topic"))
        }

        // The room must exist. Letting anyone join "room:anything" would make
        // presence lists for rooms that were never opened.
        let room: Room?
        do {
            room = try await chat.room(slug: slug, messageLimit: 0)
        } catch {
            return .reject(JoinRejection("lookup_failed"))
        }
        guard let room, !room.archived else {
            return .reject(JoinRejection(room == nil ? "no_such_room" : "room_archived"))
        }

        await presence.track(
            topic: topic,
            key: principal.subject,
            payload: ["status": "online", "since": Self.timestamp()],
            socket: socket)
        // State first, then diffs. `sendState` waits for the membership to be
        // fully established, so the client sees reply → state → diffs with no
        // window a change could fall through.
        await presence.sendState(topic: topic, to: socket)

        return .ok(initialState: ["room": .string(room.slug), "name": .string(room.name)])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        guard let principal = socket.principal else { return .error(reason: "unauthenticated") }

        switch event.event {
        case "new_msg":
            return await postMessage(event, from: principal.subject, socket: socket)

        case "status":
            guard let status = event.payload["status"]?.stringValue,
                Self.allowedStatuses.contains(status)
            else {
                return .error(reason: "status must be one of: \(Self.allowedStatuses.sorted().joined(separator: ", "))")
            }
            await presence.update(
                topic: event.topic,
                key: principal.subject,
                payload: ["status": status, "since": Self.timestamp()],
                socket: socket)
            return .reply(["status": .string(status)])

        default:
            // Naming the event back is safe — it came from this client — and
            // saves a round trip through the server log to find a typo.
            return .error(reason: "unknown_event: \(event.event)")
        }
    }

    // MARK: - Posting

    /// Persist first, broadcast second.
    ///
    /// The order matters and is the interesting part of this file: a message
    /// that fans out to twenty subscribers and then fails to insert has been
    /// *seen* by everyone and *exists* for no one, and no amount of retrying
    /// puts that back. Writing first means the worst case is a message that
    /// is durable but arrives late — which the client's own history fetch
    /// repairs on its next load.
    private func postMessage(
        _ event: InboundEvent, from sender: String, socket: Socket
    ) async -> HandleResult {
        guard let body = event.payload["body"]?.stringValue, !body.isEmpty else {
            return .error(reason: "body is required")
        }
        guard let slug = Self.roomSlug(from: event.topic) else {
            return .error(reason: "malformed_topic")
        }

        do {
            guard let room = try await chat.room(slug: slug, messageLimit: 0) else {
                return .error(reason: "no_such_room")
            }
            let authors = try await chat.authorIDs(forNames: [sender])
            let message = ChatMessage(
                id: UUID(), room: room.slug, roomID: room.id, sender: sender,
                body: body, authorID: authors[sender], parentID: nil,
                mentions: Self.mentions(in: event.payload), sentAt: Date())
            let stored = try await chat.post([message])

            // Fan-out is PubSub's job, not this channel's — this call reaches
            // subscribers on every node without knowing how many there are.
            //
            // `excluding:` keeps the sender from seeing their own message
            // twice: they receive the canonical row as the reply below, so
            // the broadcast is for everyone else.
            let persisted = stored.first ?? message
            await broadcaster.broadcast(
                topic: event.topic,
                event: "new_msg",
                payload: Self.wire(persisted),
                excluding: socket)

            // Same table, same derived digests, same eviction as the REST
            // path — the two write paths cannot be allowed to disagree about
            // when a cached aggregate went stale.
            try? await digests.messagesChanged()

            return .reply(Self.wire(persisted))
        } catch {
            // The reason is deliberately coarse. Detail belongs in the log,
            // not on a wire a client reads.
            return .error(reason: "post_failed")
        }
    }

    // MARK: - Helpers

    static let allowedStatuses: Set<String> = ["online", "away", "typing"]

    /// `"room:general"` → `"general"`. Returns nil for anything that is not
    /// this channel's shape, so a malformed topic is refused rather than
    /// silently treated as a room named "".
    static func roomSlug(from topic: String) -> String? {
        guard topic.hasPrefix("room:") else { return nil }
        let slug = String(topic.dropFirst("room:".count))
        return slug.isEmpty ? nil : slug
    }

    static func mentions(in payload: JSONValue) -> [String] {
        guard case .array(let raw)? = payload["mentions"] else { return [] }
        return raw.compactMap(\.stringValue)
    }

    static func timestamp() -> String { Date().formatted(.iso8601) }

    /// One place deciding what a message looks like on the wire, so the
    /// WebSocket broadcast and any future REST push cannot drift apart.
    static func wire(_ message: ChatMessage) -> JSONValue {
        [
            "id": .string(message.id.uuidString),
            "room": .string(message.room),
            "sender": .string(message.sender),
            "body": .string(message.body),
            "mentions": .array(message.mentions.map(JSONValue.string)),
            "sentAt": .string(message.sentAt.formatted(.iso8601)),
        ]
    }
}

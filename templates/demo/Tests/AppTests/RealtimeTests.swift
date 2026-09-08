import FlightChannels
import FlightChannelsClient
import FlightChannelsProtocol
import FlightChannelsTesting
import FlightCore
import FlightPresence
import FlightPresenceClient
import FlightPubSub
import FlightSecurityCore
import FlightWeb
import FlightWebTesting
import Foundation
import Testing

@testable import App

/// The demo's real-time path, end to end: a real `ChannelClient` over a real
/// upgrade, through the real Channels router, the real PubSub fan-out, and the
/// real Presence CRDT. Only the database is faked.
///
/// This is the suite that proves the thing the demo previously only claimed —
/// that a chat app built on Flight actually delivers messages and presence to
/// the people in the room.
private struct RealtimeModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [FlightChannelsModule.self, FlightPresenceModule.self]
    }

    let store: FakeRoomStore

    /// `FlightModule` requires a no-argument init because bootstrap
    /// instantiates modules itself. `TestContainer.build` takes ready-made
    /// *instances* though, so the real initializer below is the one the suite
    /// uses — and each test gets its own store, which matters because
    /// swift-testing runs tests in parallel.
    init() { self.store = FakeRoomStore() }

    init(store: FakeRoomStore) { self.store = store }

    func configure(_ container: Container) throws {
        let store = self.store
        container.register((any RoomStore).self, scope: .singleton) { _ in store }
        container.register((any TokenValidator).self, scope: .singleton) { _ in
            DemoTokenValidator()
        }
        container.registerChannel("room:*") { c in
            RoomChannel(
                broadcaster: try c.resolve(ChannelBroadcaster.self),
                presence: try c.resolve((any Presence).self),
                chat: try c.resolve((any RoomStore).self),
                digests: NoopDigests())
        }
        // The real route, not a stand-in: `SocketController` is what the
        // application ships, so registering it here is what makes these
        // tests exercise the upgrade path users actually get.
        try SocketController._flightRegister(container)
    }
}

private struct Harness {
    let container: Container
    let testClient: TestClient
    let store: FakeRoomStore

    init(store: FakeRoomStore) throws {
        self.store = store
        let configuration = Configuration(values: [
            "flight.channels.heartbeat-check-interval-seconds": "0.05"
        ])
        self.container = try TestContainer.build(configuration: configuration) {
            // PubSub takes its configuration, so it is supplied rather than
            // instantiated from its type by the dependency walk.
            try FlightPubSubModule(configuration: configuration)
            RealtimeModule(store: store)
        }
        self.testClient = try TestClient(container: container)
    }

    /// A client authenticated as `subject`. The token rides in the query
    /// string because a browser cannot set headers on a WebSocket handshake —
    /// the same reason the real app reads it there.
    func client(as subject: String, roles: String = "") -> ChannelClient {
        let token = roles.isEmpty ? "demo:\(subject)" : "demo:\(subject):\(roles)"
        return ChannelClient(
            url: URL(string: "flight-test:///socket")!,
            transport: InMemoryChannelTransport(testClient: testClient, query: "token=\(token)"))
    }

    /// A client with no credential at all.
    func anonymousClient() -> ChannelClient {
        ChannelClient(
            url: URL(string: "flight-test:///socket")!,
            transport: InMemoryChannelTransport(testClient: testClient))
    }
}

@Suite("Demo real-time — channels, presence, and the join gate")
struct RealtimeTests {

    @Test("an authenticated join is admitted and answers with the room")
    func joinAdmitsAuthenticated() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))
        let client = harness.client(as: "ada")
        try await client.connect()

        let reply = try await client.channel("room:general").join()

        #expect(reply["room"]?.stringValue == "general")
        #expect(reply["name"]?.stringValue == "General")
        await client.disconnect()
    }

    @Test("an anonymous socket cannot join a room")
    func joinRejectsAnonymous() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))
        let client = harness.anonymousClient()
        try await client.connect()

        // The gate is the join, not the connect: an anonymous socket is a
        // legitimate thing to hold — it simply cannot enter a room.
        await #expect(throws: (any Error).self) {
            try await client.channel("room:general").join()
        }
        await client.disconnect()
    }

    @Test("a room that does not exist is refused, not conjured")
    func joinRejectsUnknownRoom() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))
        let client = harness.client(as: "ada")
        try await client.connect()

        await #expect(throws: (any Error).self) {
            try await client.channel("room:nonexistent").join()
        }
        await client.disconnect()
    }

    @Test("an archived room is refused")
    func joinRejectsArchivedRoom() async throws {
        let harness = try Harness(
            store: FakeRoomStore(rooms: [.fixture(slug: "attic", archived: true)]))
        let client = harness.client(as: "ada")
        try await client.connect()

        await #expect(throws: (any Error).self) {
            try await client.channel("room:attic").join()
        }
        await client.disconnect()
    }

    @Test("a message is persisted before it is broadcast")
    func messagePersistedThenBroadcast() async throws {
        let store = FakeRoomStore(rooms: [.fixture(slug: "general")])
        let harness = try Harness(store: store)
        let ada = harness.client(as: "ada")
        try await ada.connect()
        let channel = ada.channel("room:general")
        _ = try await channel.join()

        let reply = try await channel.push("new_msg", payload: ["body": "hello"])

        // The sender gets the canonical row back, so an optimistic render can
        // be reconciled against what was actually stored.
        #expect(reply["body"]?.stringValue == "hello")
        #expect(reply["sender"]?.stringValue == "ada")
        #expect(reply["id"]?.stringValue != nil)
        #expect(store.posted.count == 1)
        #expect(store.posted.first?.body == "hello")
        await ada.disconnect()
    }

    @Test("a failed write broadcasts nothing")
    func failedWriteDoesNotBroadcast() async throws {
        let store = FakeRoomStore(rooms: [.fixture(slug: "general")])
        store.failPosts()
        let harness = try Harness(store: store)

        let ada = harness.client(as: "ada")
        try await ada.connect()
        let adaChannel = ada.channel("room:general")
        _ = try await adaChannel.join()

        let bob = harness.client(as: "bob")
        try await bob.connect()
        let bobChannel = bob.channel("room:general")
        _ = try await bobChannel.join()

        let seen = MessageCollector(channel: bobChannel, event: "new_msg")

        await #expect(throws: (any Error).self) {
            try await adaChannel.push("new_msg", payload: ["body": "doomed"])
        }

        // Nothing stored, so nothing may have been seen. A message that fans
        // out and then fails to insert has been read by everyone and exists
        // for no one — which no retry can repair.
        #expect(store.posted.isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        #expect(await seen.count == 0)

        await ada.disconnect()
        await bob.disconnect()
    }

    @Test("a message reaches the other people in the room, not its sender")
    func broadcastReachesOthers() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))

        let ada = harness.client(as: "ada")
        try await ada.connect()
        let adaChannel = ada.channel("room:general")
        _ = try await adaChannel.join()

        let bob = harness.client(as: "bob")
        try await bob.connect()
        let bobChannel = bob.channel("room:general")
        _ = try await bobChannel.join()

        let bobSaw = MessageCollector(channel: bobChannel, event: "new_msg")
        let adaSaw = MessageCollector(channel: adaChannel, event: "new_msg")

        _ = try await adaChannel.push("new_msg", payload: ["body": "hello room"])
        try await Task.sleep(for: .milliseconds(150))

        #expect(await bobSaw.bodies == ["hello room"])
        // The sender already has it, as the push reply — delivering it twice
        // is what `excluding:` exists to prevent.
        #expect(await adaSaw.count == 0)

        await ada.disconnect()
        await bob.disconnect()
    }

    @Test("presence lists everyone in the room, and drops them when they go")
    func presenceTracksMembership() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))
        let presence = try harness.container.resolve((any Presence).self)

        let ada = harness.client(as: "ada")
        try await ada.connect()
        _ = try await ada.channel("room:general").join()

        let bob = harness.client(as: "bob")
        try await bob.connect()
        _ = try await bob.channel("room:general").join()

        try await eventually { await presence.list(topic: "room:general").count == 2 }
        let keys = await presence.list(topic: "room:general").map(\.key).sorted()
        #expect(keys == ["ada", "bob"])

        // Nothing calls untrack. Presence is bound to the socket's membership,
        // so dropping the connection is what removes them.
        await bob.disconnect()
        try await eventually { await presence.list(topic: "room:general").count == 1 }
        let remaining = await presence.list(topic: "room:general").map(\.key)
        #expect(remaining == ["ada"])

        await ada.disconnect()
    }

    @Test("one identity in two tabs is one key with two metas")
    func oneIdentityManyConnections() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))
        let presence = try harness.container.resolve((any Presence).self)

        let tabOne = harness.client(as: "ada")
        try await tabOne.connect()
        _ = try await tabOne.channel("room:general").join()

        let tabTwo = harness.client(as: "ada")
        try await tabTwo.connect()
        _ = try await tabTwo.channel("room:general").join()

        try await eventually {
            await presence.list(topic: "room:general").first?.metas.count == 2
        }
        let entries = await presence.list(topic: "room:general")
        #expect(entries.count == 1, "one identity is one key")
        #expect(entries.first?.metas.count == 2, "two connections are two metas")

        // Closing one tab leaves the person present through the other — the
        // distinction a bare list of names would lose.
        await tabOne.disconnect()
        try await eventually {
            await presence.list(topic: "room:general").first?.metas.count == 1
        }
        #expect(await presence.list(topic: "room:general").count == 1)

        await tabTwo.disconnect()
    }

    @Test("an unknown status is refused rather than recorded")
    func statusValidation() async throws {
        let harness = try Harness(store: FakeRoomStore(rooms: [.fixture(slug: "general")]))
        let ada = harness.client(as: "ada")
        try await ada.connect()
        let channel = ada.channel("room:general")
        _ = try await channel.join()

        let ok = try await channel.push("status", payload: ["status": "away"])
        #expect(ok["status"]?.stringValue == "away")

        await #expect(throws: (any Error).self) {
            try await channel.push("status", payload: ["status": "invisible"])
        }
        await ada.disconnect()
    }
}

// MARK: - Test support

/// The real-time path's only use of the digest service is "tell it something
/// changed"; nothing here asserts on caching, so the seam is satisfied and
/// ignored.
private struct NoopDigests: DigestInvalidating {
    func messagesChanged() async throws {}
}

/// Collects inbound events of one name from a channel.
private actor MessageCollector {
    private var received: [JSONValue] = []

    init(channel: ChannelHandle, event: String) {
        Task { [weak self] in
            for await message in await channel.messages() where message.event == event {
                await self?.append(message.payload)
            }
        }
    }

    private func append(_ payload: JSONValue) { received.append(payload) }

    var count: Int { received.count }
    var bodies: [String] { received.compactMap { $0["body"]?.stringValue } }
}

/// Polls until `condition` holds or the deadline passes — the shape every
/// assertion about a distributed side effect needs, since "has the diff
/// arrived yet" is not answerable synchronously.
private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition never became true within \(timeout)")
}

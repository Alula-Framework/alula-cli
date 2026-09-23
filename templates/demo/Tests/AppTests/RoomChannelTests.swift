import AlulaChannelsProtocol
import Foundation
import Testing

@testable import App

/// The decisions `RoomChannel` makes before it ever touches a database.
///
/// Topic parsing and the wire shape are worth pinning on their own: the topic
/// is what authorization keys off, and the wire shape is a contract two
/// separate code paths (the WebSocket handler and the REST controller) both
/// produce. If those two ever disagree, clients see the same message in two
/// shapes depending on how it was sent.
@Suite("RoomChannel — topic parsing and wire shape")
struct RoomChannelTests {

    @Test("a well-formed topic yields its room slug")
    func topicParsing() {
        #expect(RoomChannel.roomSlug(from: "room:general") == "general")
        #expect(RoomChannel.roomSlug(from: "room:a:b") == "a:b")
    }

    @Test("anything that is not this channel's shape is refused, not coerced")
    func malformedTopics() {
        // "room:" is the interesting one: dropping the prefix leaves an empty
        // string, and treating that as a room named "" would create presence
        // lists for a room nobody can name.
        for bad in ["room:", "room", "lobby", "", "rooms:general", "Room:general"] {
            #expect(RoomChannel.roomSlug(from: bad) == nil, "\(bad) should not parse")
        }
    }

    @Test("the wire shape carries exactly the public fields")
    func wireShape() throws {
        let id = UUID()
        let message = ChatMessage(
            id: id, room: "general", roomID: UUID(), sender: "ada",
            body: "hello", authorID: nil, parentID: nil,
            mentions: ["grace"], sentAt: Date(timeIntervalSince1970: 0))

        let wire = RoomChannel.wire(message)

        #expect(wire["id"]?.stringValue == id.uuidString)
        #expect(wire["room"]?.stringValue == "general")
        #expect(wire["sender"]?.stringValue == "ada")
        #expect(wire["body"]?.stringValue == "hello")
        if case .array(let mentions)? = wire["mentions"] {
            #expect(mentions.compactMap(\.stringValue) == ["grace"])
        } else {
            Issue.record("mentions should be an array")
        }
        // Internal identifiers stay internal: a client has no use for the
        // room's UUID when it already addressed the room by slug, and
        // `redacted`/`authorID` are not this event's business.
        #expect(wire["roomID"] == nil)
        #expect(wire["authorID"] == nil)
    }

    @Test("mentions are read defensively from client payload")
    func mentionsParsing() {
        #expect(RoomChannel.mentions(in: ["mentions": .array([.string("ada")])]) == ["ada"])
        // Absent, wrong-typed, and mixed payloads all degrade to something
        // sane rather than throwing — this is client input.
        #expect(RoomChannel.mentions(in: ["body": "hi"]).isEmpty)
        #expect(RoomChannel.mentions(in: ["mentions": "ada"]).isEmpty)
        #expect(RoomChannel.mentions(in: ["mentions": .array([.string("a"), .number(1)])]) == ["a"])
    }

    @Test("only known statuses are accepted")
    func statuses() {
        #expect(RoomChannel.allowedStatuses.contains("online"))
        #expect(RoomChannel.allowedStatuses.contains("away"))
        #expect(RoomChannel.allowedStatuses.contains("typing"))
        #expect(!RoomChannel.allowedStatuses.contains("invisible"))
    }
}

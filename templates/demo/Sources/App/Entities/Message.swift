import Foundation
import AlulaDataPostgres
import AlulaWeb

/// A chat message, and the demo's most heavily-related entity: it belongs to
/// a room, optionally belongs to an author and to a parent message, and
/// carries topics through a join table.
///
/// `mentions` is a plain Postgres `text[]`. Nothing special is needed for
/// it — `Column<[String]>` falls out of the ordinary generic column path.
@Entity("messages")
struct ChatMessage: Encodable, Equatable, Sendable, ResponseEncodable {
    @ID var id: UUID
    /// The room's slug, kept from the pre-`rooms` schema so old rows still
    /// read naturally. `roomID` is the real relationship.
    var room: String
    @Column("roomID") var roomID: UUID
    var sender: String
    var body: String
    /// Null when the sender never registered as a user.
    @Column("authorID") var authorID: UUID?
    /// Null for a top-level message; set on a reply. A self-reference is not
    /// expressible as a stored association — `Loadable` is a plain value
    /// type, so a `ChatMessage` inside a `ChatMessage` has no layout — which
    /// is exactly why threading is read with an aliased self-join instead.
    /// See `ChatRepository.thread(rootID:)`.
    @Column("parentID") var parentID: UUID?
    var mentions: [String] = []
    var redacted: Bool = false
    @Column("sentAt") var sentAt: Date

    @BelongsTo(foreignKey: \ChatMessage.roomID)
    var roomRef: Loadable<Room> = .notLoaded(association: "roomRef")

    /// A nullable foreign key pairs with `Loadable<User?>`: `.loaded(nil)`
    /// means "preloaded, and there genuinely is no author" — which is not
    /// the same as `.notLoaded`.
    @BelongsTo(foreignKey: \ChatMessage.authorID)
    var author: Loadable<User?> = .notLoaded(association: "author")

    @HasMany(through: MessageTopic.self, from: \MessageTopic.messageID, to: \MessageTopic.topicID)
    var topics: Loadable<[Topic]> = .notLoaded(association: "topics")
}

/// Opting into runtime-sourced filters. This dictionary is the entire trusted
/// surface: a query-string field that isn't a key here does not exist as far
/// as filtering is concerned, and asking for one throws rather than reaching
/// SQL. `body` is deliberately absent — equality on a message body is not a
/// search anyone wants, and leaving it out keeps the allowlist honest about
/// what it is for.
extension ChatMessage: DynamicallyFilterable {
    static let filterable: [String: AnyColumn<ChatMessage>] = [
        "room": AnyColumn(\ChatMessage.room),
        "roomID": AnyColumn(\ChatMessage.roomID),
        "sender": AnyColumn(\ChatMessage.sender),
        "authorID": AnyColumn(\ChatMessage.authorID),
        "parentID": AnyColumn(\ChatMessage.parentID),
        "redacted": AnyColumn(\ChatMessage.redacted),
    ]
}

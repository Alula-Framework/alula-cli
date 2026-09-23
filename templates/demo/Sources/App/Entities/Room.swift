import Foundation
import AlulaDataPostgres
import AlulaWeb

/// A chat room. The parent side of the demo's one-to-many: one room, many
/// messages, reached with `.preload(\.messages)`.
@Entity("rooms")
struct Room: Encodable, Equatable, Sendable, ResponseEncodable {
    @ID var id: UUID
    var slug: String
    var name: String
    var archived: Bool
    @Column("createdAt") var createdAt: Date

    /// Not a column — nothing decodes into it, and it stays `.notLoaded`
    /// until a query says `.preload(\.messages)`. That distinction is the
    /// whole point of `Loadable`: an empty room and an unloaded room are
    /// different facts, and the type keeps them apart.
    @HasMany(foreignKey: \ChatMessage.roomID)
    var messages: Loadable<[ChatMessage]> = .notLoaded(association: "messages")
}

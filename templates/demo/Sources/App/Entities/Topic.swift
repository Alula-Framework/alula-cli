import Foundation
import AlulaDataPostgres
import AlulaWeb

/// A tag a message can carry. Reached from `ChatMessage` through
/// `MessageTopic` — a many-to-many, which Hangar preloads as two batched
/// queries rather than a join.
@Entity("topics")
struct Topic: Codable, Equatable, Sendable, ResponseEncodable {
    @ID var id: UUID
    var label: String
}

/// The join table itself, modelled as an ordinary entity because
/// `@HasMany(through:)` needs a `Table` to query.
@Entity("messageTopics")
struct MessageTopic: Codable, Equatable, Sendable {
    @ID var id: UUID
    @Column("messageID") var messageID: UUID
    @Column("topicID") var topicID: UUID
}

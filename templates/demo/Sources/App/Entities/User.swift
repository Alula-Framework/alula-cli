import Foundation
import AlulaDataPostgres
import AlulaWeb

// MARK: - Entities (Hangar @Entity — hangar-design §4)

/// A typo'd column, a type-mismatched comparison, or a reference to a
/// non-stored property in a query is a COMPILE error, not a runtime surprise.
/// Column names are camelCase via @Column where they differ from Hangar's
/// snake_case default — the migrated schema predates that convention.
@Entity("users")
struct User: Encodable, Equatable, Sendable, ResponseEncodable {
    @ID var id: UUID
    var name: String
    var email: String
    @Column("createdAt") var createdAt: Date
    @Column("updatedAt") var updatedAt: Date

    /// Everything this user wrote. `messages."authorID"` is nullable — a
    /// message from someone who never registered has no author — so the
    /// has-many is over an optional foreign key. Rows with a NULL author
    /// simply belong to nobody and appear under no user.
    @HasMany(foreignKey: \ChatMessage.authorID)
    var authored: Loadable<[ChatMessage]> = .notLoaded(association: "authored")
}

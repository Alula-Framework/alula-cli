import AlulaDataPostgres
import AlulaWeb
import Foundation

/// A row, as a Swift value.
///
/// The column names in queries are checked at compile time: a typo, a
/// type-mismatched comparison, or a reference to a property that is not a
/// column is a build error rather than a runtime surprise.
///
/// `@Column` is needed only where the Swift name and the SQL name differ.
@Entity("users")
struct User: Encodable, Equatable, Sendable, ResponseEncodable {
    @ID var id: UUID
    var name: String
    var email: String
    @Column("createdAt") var createdAt: Date
    @Column("updatedAt") var updatedAt: Date
}

import AlulaDataPostgres
import Foundation

/// The seam the rest of the application depends on instead of the concrete,
/// Postgres-bound repository.
///
/// A struct wrapping a live database scope cannot be swapped out; a protocol
/// can. This is what lets this package's tests run the real controller, the
/// real routing, and the real dependency injection with no database anywhere
/// in the loop.
protocol UserRepositoryProtocol: Sendable {
    func all() async throws -> [User]
    func find(byID id: UUID) async throws -> User?
    func find(byEmail email: String) async throws -> User?
    func create(name: String, email: String) async throws -> User
}

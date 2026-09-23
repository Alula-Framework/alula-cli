import AlulaDataPostgres
import Foundation

/// The seam `UserService` depends on instead of the concrete, Postgres-bound
/// `UserRepository` — a struct wrapping a live scope can't be swapped out
/// for anything; a protocol can. `UserService`'s `@Inject var
/// repository: (any UserRepositoryProtocol)` still resolves through the
/// ordinary `@Service` pipeline — the registration generator bridges this
/// existential key to a real `UserRepository` (tests bridge it to a fake
/// instead). `UserRepository` conforms below, for free — its method
/// signatures already match.
///
/// `apply` takes the `Changeset` itself (not `ValidatedChanges`): Hangar's
/// `Repo` consumes changesets directly (hangar-design §11.2) — validation
/// still throws before anything reaches the wire.
protocol UserRepositoryProtocol: Sendable {
    func all() async throws -> [User]
    func find(byID id: UUID) async throws -> User?
    func find(byEmail email: String) async throws -> User?
    func apply(_ changeset: Changeset<User>) async throws
}

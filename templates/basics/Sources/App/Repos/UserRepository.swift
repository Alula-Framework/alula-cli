import AlulaDataPostgres
import Foundation

/// Data access.
///
/// The repository holds the *pool* and leases a connection for each
/// operation — `withRepo` is that bracket. There is no request-scoped
/// connection to reason about: the borrow starts where you can see it and
/// ends when the closure returns, and two calls are two independent leases.
///
/// When several statements must share one connection — and therefore one
/// transaction — put them inside a single `withRepo`, and use Hangar's own
/// `repo.transaction { }` inside that.
@Repository
struct UserRepository: UserRepositoryProtocol {
    /// The pool, registered by `PostgresDataModule<PrimaryDataSource>`.
    ///
    /// `alula:hand-registered` tells the registration generator that this
    /// type is registered by a module rather than scanned from this target,
    /// so it does not warn about a component it cannot see.
    // alula:hand-registered — PostgresDataModule registers the pool.
    @Inject var pool: PostgresDataSource

    func all() async throws -> [User] {
        try await pool.withRepo { repo in
            try await repo.all(User.all.order { $0.createdAt.desc() })
        }
    }

    func find(byID id: UUID) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(User.where { $0.id == id })
        }
    }

    func find(byEmail email: String) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(User.where { $0.email == email })
        }
    }

    func create(name: String, email: String) async throws -> User {
        let now = Date()
        return try await pool.withRepo { repo in
            try await repo.insert(
                User(id: UUID(), name: name, email: email, createdAt: now, updatedAt: now))
        }
    }
}

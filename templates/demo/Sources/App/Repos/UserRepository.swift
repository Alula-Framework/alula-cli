import Foundation
import FlightDataPostgres

/// The one thing signup can fail on that isn't a validation error.
enum SignupError: Error, Sendable {
    case noLobby
}

@Repository
struct UserRepository: UserRepositoryProtocol {
    /// The pool. Each method leases a connection for its own work and gives
    /// it back; a unit of work that must share one connection says so by
    /// putting every statement inside a single `withRepo`.
    // flight:hand-registered — PostgresDataModule registers the pool.
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

    /// Atomic signup. The lobby announcement is written FIRST so a
    /// duplicate-email failure on the user insert provably rolls it back.
    ///
    /// The transaction is Hangar's, and its extent is visible: one lease,
    /// one `transaction { }`, both writes on the `tx` repo it hands you.
    /// Using the outer `repo` inside would run that statement beside the
    /// transaction rather than in it — which is why the closure gives you a
    /// different one to use.
    func signup(name: String, email: String) async throws -> User {
        try await pool.withRepo { repo in
            try await repo.transaction { tx in
                // The lobby is a real row, not a free-text label, so the
                // announcement needs its id. Rooms are created by the
                // migration's backfill and by ChatRepository.openRoom.
                guard let lobby = try await tx.one(Room.where { $0.slug == "lobby" }) else {
                    throw SignupError.noLobby
                }
                try await tx.insert(
                    ChatMessage(
                        id: UUID(), room: lobby.slug, roomID: lobby.id, sender: "system",
                        body: "\(name) joined the demo", sentAt: Date()))
                let now = Date()
                return try await tx.insert(
                    User(id: UUID(), name: name, email: email, createdAt: now, updatedAt: now))
            }
        }
    }

    /// Dirty-column-only UPDATE (or INSERT) from a changeset — identity
    /// decides which, exactly as the changeset design's driver boundary
    /// specifies.
    func apply(_ changeset: Changeset<User>) async throws {
        try await pool.withRepo { repo in
            if changeset.original == nil {
                _ = try await repo.insert(changeset)
            } else {
                _ = try await repo.update(changeset)
            }
        }
    }
}

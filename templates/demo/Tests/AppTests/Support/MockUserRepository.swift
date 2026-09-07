import FlightCore
import FlightDataPostgres
import Foundation
import Synchronization
@testable import App

/// An in-memory stand-in for `UserRepository` — no container, no Postgres,
/// just a fixed set of users. `Mutex`-guarded state so the type is genuinely
/// `Sendable`, the same shape as the project's other recording fakes
/// (`RecordingCoordinator`, `RecordingAdapter`, `InMemoryDataSource`).
final class MockUserRepository: UserRepositoryProtocol, Sendable {
    private struct State {
        var users: [User]
        var appliedChangesets: [Changeset<User>] = []
    }
    private let state: Mutex<State>

    init(users: [User] = []) {
        state = Mutex(State(users: users))
    }

    /// What `apply(_:)` was called with, in order — lets a test assert a
    /// mutation happened without caring how the repository would have
    /// executed it against a real database.
    var appliedChangesets: [Changeset<User>] { state.withLock { $0.appliedChangesets } }

    func all() async throws -> [User] {
        state.withLock { $0.users }
    }

    func find(byID id: UUID) async throws -> User? {
        state.withLock { $0.users.first { $0.id == id } }
    }

    func find(byEmail email: String) async throws -> User? {
        state.withLock { $0.users.first { $0.email == email } }
    }

    func apply(_ changeset: Changeset<User>) async throws {
        state.withLock { $0.appliedChangesets.append(changeset) }
    }
}

/// Binds the fake under the same key the application binds the real
/// repository under.
struct FakeRepository: FlightModule {
    let repository: MockUserRepository
    init() { self.repository = MockUserRepository(users: []) }
    init(_ repository: MockUserRepository) { self.repository = repository }

    func configure(_ container: Container) throws {
        let repository = self.repository
        container.register((any UserRepositoryProtocol).self, scope: .singleton) { _ in repository }
    }
}

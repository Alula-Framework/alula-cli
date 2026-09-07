import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import Testing

@testable import App

/// The controller, its routes, and its status codes — with a fake repository
/// underneath and no database anywhere.
///
/// `Components` registers exactly the components under test, the same way the
/// application registers them; the fake is registered under the protocol the
/// controller depends on. Routing, middleware, dependency injection, request
/// decoding, and JSON encoding all run for real. `TestClient` dispatches in
/// process, so there is no socket and no port to collide with — the tests are
/// fast because the network is absent, not because the framework is stubbed.
@Suite("User routes")
struct UserControllerTests {

    private func client(_ users: InMemoryUsers = InMemoryUsers([ada])) throws -> TestClient {
        let container = try TestContainer.build {
            Components(UserController.self)
            Fake(users)
        }
        return try TestClient(container: container)
    }

    @Test("listing returns the rows the repository holds")
    func list() async throws {
        let response = await (try client()).get("/users")
        #expect(response.status == .ok)
        #expect(try response.decodeJSON([UserPayload].self).map(\.name) == ["Ada"])
    }

    @Test("fetching by id returns that user")
    func getByID() async throws {
        let response = await (try client()).get("/users/\(ada.id)")
        #expect(response.status == .ok)
        #expect(try response.decodeJSON(UserPayload.self).email == ada.email)
    }

    @Test("an id that is not a UUID is a 400, not a 500")
    func malformedID() async throws {
        #expect(await (try client()).get("/users/not-a-uuid").status == .badRequest)
    }

    @Test("an unknown id is a 404")
    func unknownID() async throws {
        #expect(await (try client()).get("/users/\(UUID())").status == .notFound)
    }

    @Test("creating a user returns 201, and the row is really stored")
    func create() async throws {
        let users = InMemoryUsers()
        let response = try await client(users).post(
            "/users", json: CreateUserRequest(name: "Grace", email: "grace@example.com"))

        #expect(response.status == .created)
        #expect(try response.decodeJSON(UserPayload.self).name == "Grace")
        // Asserting on the effect, not just the response: the fake is a real
        // object a test can interrogate afterwards.
        #expect(users.stored.map(\.email) == ["grace@example.com"])
    }

    @Test("an invalid email is refused before any SQL would run")
    func invalidEmail() async throws {
        let users = InMemoryUsers()
        let response = try await client(users).post(
            "/users", json: CreateUserRequest(name: "Nope", email: "not-an-email"))

        #expect(response.status == .badRequest)
        #expect(users.stored.isEmpty, "validation must run before the write")
    }

    @Test("a duplicate email is a conflict, not a second row")
    func duplicateEmail() async throws {
        let users = InMemoryUsers([ada])
        let response = try await client(users).post(
            "/users", json: CreateUserRequest(name: "Ada Again", email: ada.email))

        #expect(response.status == .conflict)
        #expect(users.stored.count == 1)
    }
}

/// Registers the fake under the protocol the controller depends on.
private struct Fake: FlightModule {
    let users: InMemoryUsers
    init() { self.users = InMemoryUsers() }
    init(_ users: InMemoryUsers) { self.users = users }

    func configure(_ container: Container) throws {
        let users = self.users
        container.register((any UserRepositoryProtocol).self, scope: .singleton) { _ in users }
    }
}

/// Entities are `Encodable` but deliberately not `Decodable`: once an
/// association has crossed the wire as `null`, "not loaded" and "loaded and
/// empty" are indistinguishable, and the type refuses to guess. Models go out
/// as JSON; what comes back in is a type of its own.
private struct UserPayload: Decodable {
    let id: UUID
    let name: String
    let email: String
}

import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import Testing

@testable import App

/// A controller is a struct and a route is one of its methods, so the default
/// test constructs the type with a fake and calls the method. No router, no
/// HTTP, no fixtures to register — `UserController(users:)` is the whole setup,
/// because `@Controller` only *adds* members and never rewrites your method.
///
/// The end-to-end suite below is deliberately much smaller. Both tiers matter,
/// but they answer different questions, and most questions belong here.
@Suite("User routes — called directly")
struct UserControllerTests {

    private func controller(_ users: InMemoryUsers = InMemoryUsers([ada])) -> UserController {
        UserController(users: users)
    }

    @Test("listing returns the rows the repository holds")
    func list() async throws {
        let users = try await controller().list(.mock())
        #expect(users.map(\.name) == ["Ada"])
    }

    /// `get` returns a `User` — the domain value, not a `Response`. Encoding it
    /// to JSON is the framework's job at the boundary, so the unit test asserts
    /// on the value and leaves the wire format to the end-to-end tier.
    @Test("fetching by id returns that user")
    func getByID() async throws {
        let user = try await controller().get(.mock(pathParameters: ["id": ada.id.uuidString]))
        #expect(user.email == ada.email)
    }

    /// Failures arrive as a thrown `HTTPError`, so the cause is assertable
    /// without HTTP. That an error *becomes* a 400 or a 404 on the wire is a
    /// separate claim, proved once in the end-to-end suite.
    @Test("an id that is not a UUID is refused")
    func malformedID() async {
        await #expect(throws: HTTPError.self) {
            _ = try await controller().get(.mock(pathParameters: ["id": "not-a-uuid"]))
        }
    }

    @Test("an unknown id is refused")
    func unknownID() async {
        await #expect(throws: HTTPError.self) {
            _ = try await controller().get(.mock(pathParameters: ["id": UUID().uuidString]))
        }
    }

    /// `create` returns a `Response` because it sets a status, so this one
    /// inspects the response *and* the effect — the fake is a real object the
    /// test can interrogate afterwards.
    @Test("creating a user returns 201, and the row is really stored")
    func create() async throws {
        let users = InMemoryUsers()
        let response = try await controller(users).create(
            .mock(), body: CreateUserRequest(name: "Grace", email: "grace@example.com"))

        #expect(response.status == .created)
        #expect(try response.decodeJSON(UserPayload.self).name == "Grace")
        #expect(users.stored.map(\.email) == ["grace@example.com"])
    }

    @Test("an invalid email is refused before any SQL would run")
    func invalidEmail() async throws {
        let users = InMemoryUsers()
        await #expect(throws: HTTPError.self) {
            _ = try await controller(users).create(
                .mock(), body: CreateUserRequest(name: "Nope", email: "not-an-email"))
        }
        #expect(users.stored.isEmpty, "validation must run before the write")
    }

    @Test("a duplicate email is refused, not stored a second time")
    func duplicateEmail() async throws {
        let users = InMemoryUsers([ada])
        await #expect(throws: HTTPError.self) {
            _ = try await controller(users).create(
                .mock(), body: CreateUserRequest(name: "Ada Again", email: ada.email))
        }
        #expect(users.stored.count == 1)
    }
}

/// The plumbing tier: that a path routes, a body decodes, a return value
/// encodes, and a thrown error becomes the right status. None of that is
/// visible to a direct call, and none of it needs repeating per handler — a
/// few representative paths prove the wiring once.
///
/// `TestClient` dispatches in process through the real router and encoders, so
/// there is no socket and no port to collide with.
@Suite("User routes — end to end")
struct UserRoutesEndToEndTests {

    private func client(_ users: InMemoryUsers = InMemoryUsers([ada])) throws -> TestClient {
        // `flightRoutes` is generated alongside the per-route factories and
        // returns all of them, so nothing here names a route by position — add
        // a route to the controller and this keeps working unchanged.
        return try TestClient(
            routes: UserController.flightRoutes { _ in UserController(users: users) })
    }

    /// Status, headers and body shape — the three things a client actually
    /// sees, and the three a direct call cannot show you.
    @Test("GET /users/:id routes, encodes, and answers as JSON")
    func getRoutesAndEncodes() async throws {
        let response = await (try client()).get("/users/\(ada.id)")

        #expect(response.status == .ok)
        #expect(response.headers[.contentType]?.contains("json") == true)

        // Decoded into a wire-shaped struct rather than back into `User`: an
        // entity with associations is Encodable but deliberately not Decodable,
        // because once an unloaded association has crossed the wire as `null`,
        // "not loaded" and "loaded and empty" are indistinguishable. The payload
        // type also states what this endpoint is *supposed* to return.
        let decoded = try response.decodeJSON(UserPayload.self)
        #expect(decoded.id == ada.id)
        #expect(decoded.email == ada.email)
    }

    @Test("POST /users decodes the body and answers 201")
    func createDecodesAndReports201() async throws {
        let users = InMemoryUsers()
        let response = try await (try client(users)).post(
            "/users", json: CreateUserRequest(name: "Grace", email: "grace@example.com"))

        #expect(response.status == .created)
        #expect(try response.decodeJSON(UserPayload.self).name == "Grace")
        #expect(users.stored.count == 1)
    }

    /// The mapping the unit tests deliberately leave unproven: a thrown
    /// `HTTPError` becoming a status code on the wire.
    @Test("a thrown HTTPError becomes the status the client sees")
    func errorsBecomeStatuses() async throws {
        #expect(await (try client()).get("/users/not-a-uuid").status == .badRequest)
        #expect(await (try client()).get("/users/\(UUID())").status == .notFound)
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

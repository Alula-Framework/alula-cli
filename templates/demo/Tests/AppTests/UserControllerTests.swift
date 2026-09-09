import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import Testing
@testable import App

/// UserController and UserService, with a fake repository underneath.
///
/// `Components` registers exactly what is under test, the same way the
/// application registers it. Routing, middleware, dependency injection, and
/// JSON encoding all run for real; only the database is absent.
let ada = User(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    name: "Ada", email: "ada@example.com", createdAt: Date(), updatedAt: Date())

@Suite("UserController — repository mocked, everything above it real")
struct UserControllerTests {
    /// The controller's routes, built the way a route factory does per request:
    /// the mock repository feeds a real `UserService`, which feeds the controller.
    private func userClient(_ repository: MockUserRepository) throws -> TestClient {
        let make: @Sendable (RequestContext) throws -> UserController = { _ in
            UserController(users: UserService(repository: repository))
        }
        return try TestClient(routes: [
            UserController._flightRoute_listUsers_0(make),
            UserController._flightRoute_getUser_1(make),
            UserController._flightRoute_upsertUser_2(make),
            UserController._flightRoute_createUser_3(make),
        ])
    }
    @Test("GET /user/:id returns the mocked user as JSON")
    func getUserReturnsMockedUser() async throws {
        let client = try userClient(MockUserRepository(users: [ada]))

        let response = await client.get("/user/\(ada.id)")

        #expect(response.status == .ok)
        // Decoded into a wire-shaped struct, not back into `User`. An entity
        // with associations is Encodable but deliberately not Decodable:
        // `Loadable` cannot tell "association not preloaded" from "preloaded
        // and empty" once both have crossed the wire as `null`, so the type
        // refuses to guess. Models go out as JSON; what comes back in is a
        // type of its own.
        let decoded = try response.decodeJSON(UserPayload.self)
        #expect(decoded.id == ada.id)
        #expect(decoded.name == ada.name)
        #expect(decoded.email == ada.email)
        #expect(decoded.authored == nil)
    }

    @Test("GET /user/:id 404s when the mocked repository has no match")
    func getUserReturnsNotFoundWhenMissing() async throws {
        let client = try userClient(MockUserRepository(users: [ada]))

        let response = await client.get("/user/\(UUID())")

        #expect(response.status == .notFound)
    }
}

/// The JSON shape `User` encodes to — the read side of the seam described in
/// `getUserReturnsMockedUser`.
private struct UserPayload: Decodable {
    let id: UUID
    let name: String
    let email: String
    let authored: [String]?
}

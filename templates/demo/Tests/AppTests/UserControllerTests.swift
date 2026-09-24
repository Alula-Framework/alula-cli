import AlulaCore
import AlulaMail
import AlulaQueueTesting
import AlulaWeb
import AlulaWebTesting
import Foundation
import Testing
@testable import App

/// A controller is a struct and a route is one of its methods, so the default
/// test builds the type with a fake and calls the method — no router, no HTTP.
/// `@Controller` only *adds* members (an initializer and the route factories);
/// it never rewrites your method, so `getUser` stays an ordinary function.
///
/// The end-to-end suite below is deliberately smaller: it exists to prove the
/// wiring once, not to re-test the logic.
let ada = User(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    name: "Ada", email: "ada@example.com", createdAt: Date(), updatedAt: Date())

@Suite("UserController — called directly")
struct UserControllerTests {

    private func controller(_ repository: MockUserRepository) -> UserController {
        UserController(users: UserService(repository: repository, mailer: .testing, jobs: QueueTestHarness().queue))
    }

    @Test("listUsers returns what the repository holds")
    func listUsers() async throws {
        let users = try await controller(MockUserRepository(users: [ada])).listUsers(.mock())
        #expect(users.map(\.email) == [ada.email])
    }

    /// `getUser` returns a `User` — the domain value, not a `Response`. Turning
    /// it into JSON and a status is the framework's job at the boundary, so the
    /// unit test asserts the value and leaves the wire format to the tier below.
    @Test("getUser returns the mocked user")
    func getUser() async throws {
        let user = try await controller(MockUserRepository(users: [ada]))
            .getUser(.mock(), id: ada.id)
        #expect(user.id == ada.id)
        #expect(user.email == ada.email)
    }

    /// The failure arrives as a thrown `HTTPError`, so its cause is assertable
    /// without HTTP. That it *becomes* a 404 on the wire is a separate claim,
    /// proved once end to end.
    ///
    /// There is no companion test for "the id is not a UUID": `id: UUID` is a
    /// parameter, so a malformed one cannot reach this handler and cannot be
    /// written into a call to it. The route refuses it first.
    @Test("getUser refuses an unknown id")
    func getUserUnknown() async {
        await #expect(throws: HTTPError.self) {
            _ = try await controller(MockUserRepository(users: [ada]))
                .getUser(.mock(), id: UUID())
        }
    }

    /// The update half of `upsertUser`: an existing email takes the changeset
    /// path. `upsertUser` returns a `Response` because it encodes directly, so
    /// this asserts the response *and* the effect — `appliedChangesets` is the
    /// fake recording that a write was actually attempted.
    @Test("upsertUser updates an existing user and records the changeset")
    func upsertExisting() async throws {
        let repository = MockUserRepository(users: [ada])
        let response = try await controller(repository).upsertUser(
            .mock(), body: CreateUserRequest(name: "Ada Lovelace", email: ada.email))

        #expect(response.status == .ok)
        #expect(try response.decodeJSON(UserPayload.self).email == ada.email)
        #expect(repository.appliedChangesets.count == 1)
    }

    // NOTE: the `signup` path (`createUser`, and `upsertUser` with an unseen
    // email) is not covered here. `MockUserRepository.apply` records a changeset
    // without applying it, while `UserService.signup` does
    // `apply(...)` then `find(byEmail:)!` — so against this fake the
    // force-unwrap would trap rather than fail an expectation. Covering it means
    // teaching the fake to apply what it records; see the template's TODO.
}

/// The plumbing tier: that a path routes, a body decodes, a return value
/// encodes, and a thrown error becomes the right status. A direct call shows
/// none of that — and none of it needs repeating per handler.
@Suite("UserController — end to end")
struct UserRoutesEndToEndTests {

    private func client(_ repository: MockUserRepository) throws -> TestClient {
        // `alulaRoutes` is generated alongside the per-route factories and
        // returns all of them, so nothing here names a route by position — add
        // a route to the controller and this keeps working unchanged.
        try TestClient(
            routes: UserController.alulaRoutes { _ in
                UserController(users: UserService(repository: repository, mailer: .testing, jobs: QueueTestHarness().queue))
            })
    }

    /// Status, headers and body shape — the three things a client actually
    /// sees, and the three a direct call cannot show you.
    @Test("GET /user/:id routes, encodes, and answers as JSON")
    func getUserRoutesAndEncodes() async throws {
        let response = await (try client(MockUserRepository(users: [ada])))
            .get("/user/\(ada.id)")

        #expect(response.status == .ok)
        #expect(response.headers[.contentType]?.contains("json") == true)

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

    /// The mapping the unit tests deliberately leave unproven: a thrown
    /// `HTTPError` becoming a status code on the wire.
    @Test("a thrown HTTPError becomes the status the client sees")
    func errorsBecomeStatuses() async throws {
        let response = await (try client(MockUserRepository(users: [ada])))
            .get("/user/\(UUID())")
        #expect(response.status == .notFound)
    }
}

/// The JSON shape `User` encodes to — the read side of the seam described in
/// `getUserRoutesAndEncodes`.
private struct UserPayload: Decodable {
    let id: UUID
    let name: String
    let email: String
    let authored: [String]?
}

import FlightCore
import FlightSecurityCore
import FlightSessionsTesting
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import App

/// The whole browser sign-in path, in process: the demo validator, the
/// session middleware, the security lanes, and the `"csrf"` lane sign-out
/// names — composed the way `AppModule` composes them.
@Suite("SessionController — cookie sign-in")
struct SessionControllerTests {
    private let store = RecordingSessionStore()

    private func client() throws -> TestClient {
        let validator: any TokenValidator = DemoTokenValidator()
        let sessions = try FlightSessionsModule(
            configuration: Configuration(values: ["sessions.cookie-secure": "false"]),
            store: store)
        let security = FlightSecurityModule(validator: validator, sessions: sessions.runtime)
        return try TestClient(
            routes: SessionController.flightRoutes { _ in SessionController(validator: validator) },
            middleware:
                sessions.middleware + security.middleware
                + MiddlewareRegistration.lane("csrf", [CSRFProtection()]))
    }

    private func sessionCookie(_ response: Response) -> String? {
        response.headerValues("Set-Cookie")
            .compactMap { $0.split(separator: ";").first.map(String.init) }
            .first { $0.hasPrefix("session=") }
    }

    @Test("an anonymous browser is refused; a signed-in one is recognised by its cookie")
    func signInRoundTrip() async throws {
        let client = try client()
        #expect(await client.get("/session/").status == .unauthorized)

        let signIn = try await client.post("/session/", json: SessionController.SignIn(token: "demo:ada:admin,author"))
        #expect(signIn.status == .noContent)
        let cookie = try #require(sessionCookie(signIn))

        let who = await client.get("/session/", headers: [.cookie: cookie])
        #expect(who.status == .ok)
        let identity = try who.decodeJSON(SessionController.WhoAmI.self)
        #expect(identity.subject == "ada")
        #expect(identity.roles == ["admin", "author"])
        #expect(!identity.csrfToken.isEmpty)
    }

    @Test("a bad credential is a 401 with nothing stored")
    func refused() async throws {
        let response = try await client().post("/session/", json: SessionController.SignIn(token: "not-a-demo-token"))
        #expect(response.status == .unauthorized)
        #expect(response.header("Set-Cookie") == nil)
        #expect(store.entryCount == 0)
    }

    @Test("signing out regenerates the id and the old cookie no longer signs anyone in")
    func signOut() async throws {
        let client = try client()
        let cookie = try #require(
            sessionCookie(try await client.post("/session/", json: SessionController.SignIn(token: "demo:ada"))))
        let token = try (await client.get("/session/", headers: [.cookie: cookie]))
            .decodeJSON(SessionController.WhoAmI.self).csrfToken

        let out = await client.delete(
            "/session/", headers: [.cookie: cookie, .xCSRFToken: token])
        #expect(out.status == .noContent)
        #expect(sessionCookie(out) != cookie)
        #expect(await client.get("/session/", headers: [.cookie: cookie]).status == .unauthorized)
    }

    @Test("signing out with no CSRF token, or the wrong one, is refused — the cookie still signs in")
    func signOutWithoutTokenRefused() async throws {
        let client = try client()
        let cookie = try #require(
            sessionCookie(try await client.post("/session/", json: SessionController.SignIn(token: "demo:ada"))))

        #expect(await client.delete("/session/", headers: [.cookie: cookie]).status == .forbidden)
        #expect(
            await client.delete(
                "/session/", headers: [.cookie: cookie, .xCSRFToken: "not-the-real-token"]
            ).status == .forbidden)
        #expect(await client.get("/session/", headers: [.cookie: cookie]).status == .ok)
    }
}

extension HTTPField.Name {
    /// The demo's tests live outside `FlightWeb`, so this is the public name
    /// — the same literal `CSRFProtection` checks internally, declared here
    /// because a test has no reason to `@testable import` the framework.
    fileprivate static let xCSRFToken = HTTPField.Name("x-csrf-token")!
}

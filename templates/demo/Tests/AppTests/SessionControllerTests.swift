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
/// session middleware, the security lanes, and the `"csrf"` lane sign-in and
/// sign-out name — composed the way `AppModule` composes them.
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

    /// What a browser does before it can sign in: `GET /session/csrf`, which
    /// sets the cookie the token is bound to.
    private func csrf(_ client: TestClient) async throws -> (cookie: String, token: String) {
        let response = await client.get("/session/csrf")
        #expect(response.status == .ok)
        let cookie = try #require(sessionCookie(response))
        return (cookie, try response.decodeJSON(SessionController.CSRFToken.self).csrfToken)
    }

    /// Signs in the way a browser does, and returns the new cookie and the
    /// token, which signing in keeps.
    private func signIn(
        _ client: TestClient, as credential: String
    ) async throws -> (cookie: String, token: String) {
        let (cookie, token) = try await csrf(client)
        let response = try await client.post(
            "/session/", headers: [.cookie: cookie, .xCSRFToken: token],
            json: SessionController.SignIn(token: credential))
        #expect(response.status == .noContent)
        return (try #require(sessionCookie(response)), token)
    }

    @Test("an anonymous browser is refused; a signed-in one is recognised by its cookie")
    func signInRoundTrip() async throws {
        let client = try client()
        #expect(await client.get("/session/").status == .unauthorized)

        let (cookie, token) = try await signIn(client, as: "demo:ada:admin,author")
        let who = await client.get("/session/", headers: [.cookie: cookie])
        #expect(who.status == .ok)
        let identity = try who.decodeJSON(SessionController.WhoAmI.self)
        #expect(identity.subject == "ada")
        #expect(identity.roles == ["admin", "author"])
        // Minted anonymously, kept across the sign-in's id regeneration.
        #expect(identity.csrfToken == token)
    }

    @Test("a bad credential is a 401 and signs nobody in")
    func refused() async throws {
        let client = try client()
        let (cookie, token) = try await csrf(client)
        #expect(store.entryCount == 1, "minting the token is the one anonymous write")

        let response = try await client.post(
            "/session/", headers: [.cookie: cookie, .xCSRFToken: token],
            json: SessionController.SignIn(token: "not-a-demo-token"))
        #expect(response.status == .unauthorized)
        #expect(response.header("Set-Cookie") == nil)
        #expect(await client.get("/session/", headers: [.cookie: cookie]).status == .unauthorized)
    }

    @Test("login CSRF: a sign-in without the token is refused, form-encoded or not")
    func signInWithoutTokenRefused() async throws {
        let client = try client()

        // What a hostile page's auto-submitting form sends: form-encoded, no
        // cookie of this site's at all, no token. A Codable body accepts form
        // encoding, and a form needs no preflight — so without the guard this
        // would sign the visitor in as the attacker.
        let forged = await client.post(
            "/session/", headers: [.contentType: "application/x-www-form-urlencoded"],
            body: Data("token=demo:mallory".utf8))
        #expect(forged.status == .forbidden)
        #expect(sessionCookie(forged) == nil)

        // The same with a real session cookie but no token.
        let (cookie, _) = try await csrf(client)
        let noToken = try await client.post(
            "/session/", headers: [.cookie: cookie],
            json: SessionController.SignIn(token: "demo:mallory"))
        #expect(noToken.status == .forbidden)
        #expect(await client.get("/session/", headers: [.cookie: cookie]).status == .unauthorized)
    }

    @Test("signing out regenerates the id and the old cookie no longer signs anyone in")
    func signOut() async throws {
        let client = try client()
        let (cookie, token) = try await signIn(client, as: "demo:ada")

        let out = await client.delete(
            "/session/", headers: [.cookie: cookie, .xCSRFToken: token])
        #expect(out.status == .noContent)
        #expect(sessionCookie(out) != cookie)
        #expect(await client.get("/session/", headers: [.cookie: cookie]).status == .unauthorized)
    }

    @Test("signing out with no CSRF token, or the wrong one, is refused — the cookie still signs in")
    func signOutWithoutTokenRefused() async throws {
        let client = try client()
        let (cookie, _) = try await signIn(client, as: "demo:ada")

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

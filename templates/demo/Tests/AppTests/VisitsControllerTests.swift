import AlulaCore
import AlulaSessionsTesting
import AlulaWeb
import AlulaWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import App

/// The session middleware runs for real here — `AlulaSessionsModule` built
/// the way the composition root builds it, with a recording store in place
/// of the in-memory one — so the suite proves the cookie round-trips, not
/// only that the handler reads what it wrote.
@Suite("VisitsController — through the session middleware")
struct VisitsControllerTests {
    private let store = RecordingSessionStore()

    private func client() throws -> TestClient {
        let sessions = try AlulaSessionsModule(
            configuration: Configuration(values: ["sessions.cookie-secure": "false"]),
            store: store)
        return try TestClient(
            routes: VisitsController.alulaRoutes { _ in VisitsController() },
            middleware: sessions.middleware)
    }

    /// The `session=<id>` pair from a `Set-Cookie`, ready to send back.
    private func sessionCookie(_ response: Response) -> String? {
        response.headerValues("Set-Cookie")
            .compactMap { $0.split(separator: ";").first.map(String.init) }
            .first { $0.hasPrefix("session=") }
    }

    @Test("a browser that has never visited gets an empty answer and no cookie")
    func nothingYet() async throws {
        let response = await (try client()).get("/visits/last")
        #expect(response.status == .ok)
        #expect(try response.decodeJSON(VisitsController.LastVisit.self).slug == nil)
        #expect(response.header("Set-Cookie") == nil, "a read stores nothing")
        #expect(store.entryCount == 0)
    }

    @Test("a visit sets the cookie, and the next request with it remembers")
    func remembers() async throws {
        let client = try client()
        let visit = await client.post("/visits/lobby")
        #expect(visit.status == .ok)
        let cookie = try #require(sessionCookie(visit))
        #expect(store.entryCount == 1)

        let last = await client.get("/visits/last", headers: [.cookie: cookie])
        #expect(try last.decodeJSON(VisitsController.LastVisit.self).slug == "lobby")
    }

    @Test("forgetting deletes the session and expires the cookie")
    func forgets() async throws {
        let client = try client()
        let cookie = try #require(sessionCookie(await client.post("/visits/lobby")))

        let forget = await client.delete("/visits/", headers: [.cookie: cookie])
        #expect(forget.status == .noContent)
        #expect(try #require(forget.header("Set-Cookie")).contains("Max-Age=0"))
        #expect(store.entryCount == 0)

        let last = await client.get("/visits/last", headers: [.cookie: cookie])
        #expect(try last.decodeJSON(VisitsController.LastVisit.self).slug == nil)
    }
}

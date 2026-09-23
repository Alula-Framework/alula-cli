import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Testing

@testable import App

/// Routing, dependency injection, configuration, and JSON encoding all run for
/// real here — `TestClient` dispatches in-process, so there is no socket and
/// no port to collide with, but nothing above the socket is faked.
@Suite("Health route")
struct HealthControllerTests {

    @Test("the index route answers with the configured application name")
    func index() async throws {
        // The composition root's sequence, by hand: build the graph, then the
        // routes from it — the values `AlulaWebModule` is composed with.
        let configuration = Configuration(values: ["app.name": "TestApp"])
        let graph = try AlulaGraph(configuration: configuration)
        let client = try TestClient(routes: alulaRoutes(graph))

        let response = await client.get("/")

        #expect(response.status == .ok)
        #expect(response.bodyText == "TestApp is flying")
    }
}

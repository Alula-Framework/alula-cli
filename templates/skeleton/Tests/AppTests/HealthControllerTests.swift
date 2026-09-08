import FlightCore
import FlightWeb
import FlightWebTesting
import Testing

@testable import App

/// Routing, dependency injection, configuration, and JSON encoding all run for
/// real here — `TestClient` dispatches in-process, so there is no socket and
/// no port to collide with, but nothing above the socket is faked.
@Suite("Health route")
struct HealthControllerTests {

    @Test("the index route answers with the configured application name")
    func index() async throws {
        // The composition root's sequence, by hand: the graph is built first,
        // and AppModule registers from it.
        let configuration = Configuration(values: ["app.name": "TestApp"])
        let graph = try FlightGraph(configuration: configuration)
        let container = try TestContainer.build(configuration: configuration) {
            AppModule(graph: graph)
        }
        // Routes are values the composition root hands to `FlightWebModule`,
        // so a client that serves them is handed the same list.
        let client = try TestClient(container: container, routes: flightRoutes(graph))

        let response = await client.get("/")

        #expect(response.status == .ok)
        #expect(response.bodyText == "TestApp is flying")
    }
}

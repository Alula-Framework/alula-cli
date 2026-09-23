import AlulaCore
import AlulaDataPostgres
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
        // `AppModule` now depends on the Postgres module, which needs the
        // datasource URL when the module is built. Nothing dials it here —
        // building the module opens no connection — but the key must exist,
        // which is the point: a missing one fails at startup, not at the
        // first request that needed it.
        let configuration = Configuration(values: [
            "app.name": "TestApp",
            "datasource.primary.url": "postgres://localhost/unused",
        ])
        // The composition root's sequence, by hand: the pool is a graph root,
        // the graph is built from it, and AppModule registers from the graph.
        let postgres = try PostgresDataModule<PrimaryDataSource>(configuration: configuration)
        let graph = try AlulaGraph(
            configuration: configuration, postgresDataSource: postgres.dataSource)
        // Routes are values the composition root hands to `AlulaWebModule`,
        // so a client that serves them is built from the same graph.
        let client = try TestClient(routes: alulaRoutes(graph))

        let response = await client.get("/")

        #expect(response.status == .ok)
        #expect(response.bodyText == "TestApp is flying")
    }
}

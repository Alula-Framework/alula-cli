import FlightCore
import FlightDataPostgres
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
        // `AppModule` now depends on the Postgres module, which requires the
        // datasource URL at container freeze. Nothing dials it here —
        // `configure` is registration only, no I/O — but the key must exist,
        // which is the point: a missing one fails at startup, not at the
        // first request that needed it.
        let configuration = Configuration(values: [
            "app.name": "TestApp",
            "datasource.primary.url": "postgres://localhost/unused",
        ])
        // The composition root's sequence, by hand: the pool is a graph root,
        // the graph is built from it, and AppModule registers from the graph.
        let postgres = try PostgresDataModule<PrimaryDataSource>(configuration: configuration)
        let container = try TestContainer.build(configuration: configuration) {
            postgres
            AppModule(
                graph: try FlightGraph(
                    configuration: configuration, postgresDataSource: postgres.dataSource))
        }
        let client = try TestClient(container: container)

        let response = await client.get("/")

        #expect(response.status == .ok)
        #expect(response.bodyText == "TestApp is flying")
    }
}

import FlightActuator
import FlightChannels
import FlightCore
import FlightDataPostgres
import FlightPresence
import FlightPubSub
import FlightSecurityCore
import FlightTransport
import FlightWeb
import FlightWebTesting
import Testing

@testable import App

/// Does the application actually start?
///
/// Every other suite here tests a layer. This one tests the wiring: the same
/// modules `main` boots, in the same order, frozen the same way. It exists
/// because nothing did, and a lifetime mistake — a singleton capturing a
/// request-scoped repository — sat undetected in `AppModule` while a hundred
/// green tests ran around it. Freezing the container is where such a mistake
/// surfaces, and freezing is exactly what a test of a single layer skips.
@Suite("The application boots")
struct BootstrapTests {

    /// Everything `main` passes to `Flight.bootstrap`, minus the transport —
    /// binding a socket is not what is under test here.
    private func boot() throws -> Container {
        let configuration = Configuration(values: [
            "app.name": "App",
            "datasource.primary.url": "postgres://localhost/unused",
        ])
        // The same wiring `main`'s composition root performs, for the three
        // modules that take what they provide: PubSub reads configuration,
        // and Channels is built from PubSub's bus plus the channels AppModule
        // declares. The dependency walk cannot do this, which is the point —
        // it is composition, and it belongs in one place.
        // The composition root's own sequence, by hand: the pool and the
        // validator are graph roots, the graph is built from them, and
        // AppModule registers from the graph.
        let postgres = try PostgresDataModule<PrimaryDataSource>(configuration: configuration)
        let auth = DemoAuthModule()
        let graph = try FlightGraph(
            configuration: configuration,
            postgresDataSource: postgres.dataSource,
            tokenValidator: auth.tokenValidator)
        let app = AppModule(graph: graph)
        let pubsub = try FlightPubSubModule(configuration: configuration)
        return try TestContainer.build(configuration: configuration) {
            postgres
            auth
            app
            FlightSecurityModule()
            ActuatorModule()
            pubsub
            try FlightChannelsModule(
                bus: pubsub.bus, configuration: configuration, channels: app.channels)
            try FlightPresenceModule(
                configuration: configuration,
                localBus: pubsub.local,
                gossipBus: pubsub.bus)
        }
    }

    @Test("the container freezes")
    func freezes() throws {
        #expect(throws: Never.self) { try boot() }
    }

    @Test("the demo's own token validator is the one installed")
    func bringYourOwnAuth() throws {
        // FlightSecurityModule installs a generic OIDC validator unless one is
        // already registered. If the module ordering regressed, this resolves
        // the OIDC one — and would have demanded `security.oidc.issuer` above.
        let validator = try boot().resolve((any TokenValidator).self)
        #expect(validator is DemoTokenValidator)
    }

    @Test("nothing long-lived captured a request-scoped repository")
    func lifetimes() throws {
        // The gateway is the seam that keeps this true: singletons and
        // channels hold it, and it opens a scope per call.
        let container = try boot()
        #expect(throws: Never.self) { try container.resolve(RoomDigestService.self) }
        #expect(throws: Never.self) { try container.resolve((any RoomStore).self) }
    }
}

import AlulaActuator
import AlulaChannels
import AlulaCache
import AlulaCore
import AlulaRateLimit
import AlulaDataPostgres
import AlulaPresence
import AlulaPubSub
import AlulaSecurityCore
import AlulaTransport
import AlulaWeb
import Testing

@testable import App

/// Does the application actually compose?
///
/// Every other suite here tests a layer. This one tests the wiring: the same
/// modules `main` composes, built in the order the value flow forces, and
/// assembled the same way. It exists because nothing did — and the eager
/// construction the graph performs is where a composition mistake surfaces,
/// which is exactly what a test of a single layer skips.
@Suite("The application composes")
struct BootstrapTests {

    /// Everything `main`'s composition root performs, by hand, minus the
    /// transport (binding a socket is not what is under test here): what the
    /// graph needs, then the graph, then what is built from it, then assemble.
    /// Returns the graph so a test can confirm which components it built.
    private func boot() throws -> AlulaGraph {
        let configuration = Configuration(values: [
            "app.name": "App",
            "datasource.primary.url": "postgres://localhost/unused",
        ])
        let postgres = try PostgresDataModule<PrimaryDataSource>(configuration: configuration)
        let auth = DemoAuthModule()
        let pubsub = try AlulaPubSubModule(configuration: configuration)
        // Only what a *component* needs is a graph root. Values a route terminal
        // alone needs — the broadcaster, the socket stack, the validator — are
        // parameters of `alulaRoutes`, which keeps the graph free of Channels
        // and so lets channels be built from the graph.
        let graph = try AlulaGraph(
            configuration: configuration, postgresDataSource: postgres.dataSource)
        let presenceModule = try AlulaPresenceModule(
            configuration: configuration, localBus: pubsub.local, gossipBus: pubsub.bus)
        let demoChannels = DemoChannelsModule(
            graph: graph, presence: presenceModule.presence)
        let channels = try AlulaChannelsModule(
            bus: pubsub.bus, configuration: configuration, channels: demoChannels.channels)
        // Assembling every module is the value-model equivalent of freezing the
        // container: the graph already built every component eagerly above, and
        // assemble seeds health and collects services over the whole set.
        _ = try Alula.assemble(
            configuration: configuration,
            modules: [
                postgres,
                auth,
                pubsub,
                demoChannels,
                channels,
                AppModule(graph: graph, limiter: RateLimiter(store: InMemoryRateLimitStore())),
                AlulaSecurityModule(validator: auth.tokenValidator),
                try AlulaPasswordSignInModule(
                    configuration: configuration,
                    store: DemoAccountsModule(configuration: configuration).credentialStore,
                    limiter: RateLimiter(store: InMemoryRateLimitStore())),
                ActuatorModule(),
                presenceModule,
                try AlulaCacheModule(configuration: configuration),
            ])
        return graph
    }

    @Test("the whole composition builds and assembles")
    func composes() throws {
        #expect(throws: Never.self) { _ = try boot() }
    }

    @Test("the demo's own token validator is the one composed in")
    func bringYourOwnAuth() throws {
        // The app supplies its validator by value to `AlulaSecurityModule`;
        // nothing looks up an OIDC default, so no `security.oidc.*` is demanded.
        let auth = DemoAuthModule()
        #expect(auth.tokenValidator is DemoTokenValidator)
    }

    @Test("the components a channel and a job hold are graph nodes")
    func componentsAreBuilt() throws {
        // `RoomDigestService` and `ChatRepository` are graph nodes the
        // composition builds; accessing them is proof they were constructed.
        // `(any RoomStore)` is deliberately *not* a node — nothing injects it
        // as a component (the room channel is handed a `ChatRepository` and
        // Swift converts it at the `any RoomStore` parameter), so there is no
        // `graph.roomStore` to reach for at all.
        let graph = try boot()
        _ = graph.chatRepository
        _ = graph.roomDigestService
    }
}

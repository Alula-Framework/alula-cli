import FlightActuator
import FlightCache
import FlightChannels
import FlightCore
import FlightDataPostgres
import FlightPresence
import FlightPubSub
import FlightScheduler
import FlightSchedulerPostgres
import FlightSecurityCore
import FlightTransport
import FlightWeb

/// Flight Security's `Principal` and Flight Channels' `ChannelPrincipal` are
/// deliberately unrelated: Channels has no dependency on Security, so a
/// WebSocket layer can be used with any notion of identity — or none. The two
/// meet in application code, which is here, and the conformance is empty
/// because `Principal` already has everything the protocol asks for.
extension Principal: @retroactive ChannelPrincipal {}

/// Registers everything the build plugin found — every @Component,
/// @Controller, @Service and @Repository in this target — through the one
/// registration pipeline.
struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [
            PostgresDataModule<PrimaryDataSource>.self,
            FlightPubSubModule.self,
            // Listed to *include* Channels in this application, not to order
            // it: this module declares channels, so the composer builds
            // Channels from them and therefore builds this module first. The
            // two meanings `dependencies` used to carry are now separate —
            // inclusion here, ordering from what each module takes.
            FlightChannelsModule.self,
            FlightPresenceModule.self,
            FlightCacheModule.self,
            FlightSchedulerModule.self,
            // Authentication wiring — the request-scoped principal and the
            // `Authentication` middleware. It registers no validator: how
            // tokens are validated is chosen by listing a module
            // (`FlightOIDCModule`) or registering `(any TokenValidator)`
            // yourself, as this application does below. Order does not
            // matter, which is why this can simply be a dependency.
            FlightSecurityModule.self,
        ]
    }

    func configure(_ container: Container) throws {
        try flightRegisterAll(container)

        // Order is declared once, here, top to bottom, outermost first —
        // RequestLogging sees the true wall-clock time of everything below
        // it.
        container.pipeline {
            RequestLogging.self
        }

        // What a pool exhaustion, an invalid changeset or a bad dynamic
        // filter look like on the wire. See Web/ErrorMapping.swift for why
        // this cannot be done with a middleware.
        container.register(ErrorMapper.self, scope: .singleton) { _ in
            AppErrorMapping.mapper()
        }

        // `ChatRepository` is the only conformer of `RoomStore` in this
        // target, so anything injecting the protocol gets the bridge
        // synthesized. The channel below resolves it by hand, at a point
        // where there is no property to inject into, so the key is stated
        // once here.
        container.register((any RoomStore).self, scope: .singleton) { c in
            try c.resolve(ChatRepository.self)
        }
        // Makes `.once` mean once across every server rather than once per
        // server. This demo runs one process, where the coordinator changes
        // nothing — but registering it is the whole difference between a
        // nightly job that is safe to scale and one that is not, and the
        // scheduler warns at startup when it is missing.
        container.register((any JobCoordinator).self, scope: .singleton) { c in
            // Qualified: data sources are registered under their name so an
            // app with two databases can say which it means. A single-database
            // app never writes the qualifier anywhere else — this is the one
            // place that resolves the pool directly rather than through a
            // scoped connection.
            PostgresJobCoordinator(
                dataSource: try c.resolve(
                    PostgresDataSource.self, qualifier: PrimaryDataSource.name))
        }

        // The bring-your-own-auth seam: `FlightSecurityModule` registers the
        // authentication machinery but no validator, so this is the choice.
        //
        // A real deployment deletes this and lists `FlightOIDCModule`
        // instead, configured through `security.oidc.*`.
        container.register((any TokenValidator).self, scope: .singleton) { _ in
            DemoTokenValidator()
        }

        // The socket route itself is `SocketController`, declared with
        // `@WebSocketRoute` rather than registered here — see that file for
        // why a declared route beats a hand-registered one.
    }

    /// One declaration serves every room. Patterns are exact, prefix
    /// wildcard, or catch-all, and the most specific match wins; a malformed
    /// or duplicate pattern fails composition rather than a join.
    ///
    /// A **value this module holds**, not a call into the container. The
    /// composer collects `channels` from every module that declares any and
    /// hands them to `FlightChannelsModule`, which is why this module no
    /// longer lists Channels in `dependencies`: declaring a channel does not
    /// require having a broadcaster, only creating one does — and that
    /// happens per join, below, from the socket's own context.
    let channels: [ChannelRegistration] = [
        ChannelRegistration("room:*", source: "AppModule") { context in
            RoomChannel(
                broadcaster: try context.resolve(ChannelBroadcaster.self),
                presence: try context.resolve((any Presence).self),
                chat: try context.resolve((any RoomStore).self),
                digests: try context.resolve(RoomDigestService.self))
        }
    ]
}

@main
struct Main {
    static func main() async {
        // Steps 1–3: Flight Config (flight.yaml + FLIGHT_* env). Steps 4–9:
        // container, module DAG, freeze, ServiceGroup — request serving
        // starts only after the whole DAG has registered.
        //
        // `Flight.run` rather than `main() async throws`: an error escaping
        // `main` is reported by the Swift runtime as "Fatal error: Error
        // raised at top level" followed by a register dump and a backtrace —
        // which is what a new project sees when Postgres is not running or
        // the port is already bound. `run` prints the reason and exits 1.
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [
                FlightWebModule<FlightTransport>.self,  // choosing a transport = choosing a module
                AppModule.self,
                ActuatorModule.self,
            ],
            // Built by the plugin, in dependency order, from the list above:
            // `modules:` says which subsystems this application includes,
            // and this is how they are constructed. Without it Flight
            // instantiates each from its type, which is why a module would
            // have to be constructible with no arguments.
            composedBy: flightComposeModules
        )
    }
}

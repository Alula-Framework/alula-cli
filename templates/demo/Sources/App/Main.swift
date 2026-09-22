import FlightActuator
import FlightCache
import FlightChannels
import FlightCore
import FlightDataPostgres
import FlightPresence
import FlightPubSub
import FlightRateLimit
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

/// The bring-your-own-auth seam: `FlightSecurityModule` wires the
/// authentication machinery but supplies no validator, so this is the choice.
///
/// Its own module because the validator is a *root* of the component graph —
/// `SocketController` injects it — and the graph is built before the modules
/// that register from it. `AppModule` both needing the graph and providing one
/// of its roots would be a composition cycle, which the build would refuse by
/// name. Separating them says the true thing anyway: choosing how tokens are
/// validated is a deployment decision, and a real one deletes this and lists
/// `FlightOIDCModule` instead, configured through `security.oidc.*`.
struct DemoAuthModule: FlightModule {
    /// Provided as a value; the composer matches it to `FlightSecurityModule`'s
    /// `validator:` by type. It used to be a container registration the
    /// security module looked up.
    let tokenValidator: any TokenValidator = DemoTokenValidator()
}

struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [
            PostgresDataModule<PrimaryDataSource>.self,
            FlightPubSubModule.self,
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
            // Sessions: a cookie-keyed record per browser, loaded ahead of
            // every request and persisted after it. In-memory here, which is
            // right for one process; `FlightSessionsValkeyModule` from
            // flight-data makes it shared when there are more.
            FlightSessionsModule.self,
            // Rate limiting. Same story about one process:
            // `FlightRateLimitValkeyModule` makes a quota mean one thing
            // across every replica instead of one thing per replica.
            FlightRateLimitModule.self,
        ]
    }

    /// Every component, already built by the composition root. It used to be
    /// constructed from the container at `freeze()`; the graph's roots are
    /// things modules provide, so the place that assembles the modules is the
    /// place that can build it.
    let graph: FlightGraph

    /// Makes `.once` mean once across every server rather than once per
    /// server. This demo runs one process, where the coordinator changes
    /// nothing — but providing it is the whole difference between a nightly
    /// job that is safe to scale and one that is not, and the scheduler warns
    /// at startup when it is missing.
    ///
    /// A value the composition root hands to `FlightSchedulerModule` (matched
    /// by type). It used to be a container registration the scheduler looked
    /// up, which meant a deployment that forgot it degraded silently.
    let jobCoordinator: any JobCoordinator

    /// What a pool exhaustion, an invalid changeset or a bad dynamic filter
    /// look like on the wire, handed to `FlightWebModule` (matched by type).
    /// See Web/ErrorMapping.swift for why this cannot be a middleware.
    let errorMapper: ErrorMapper

    /// The application's default-lane middleware, outermost first — the value
    /// form of `container.pipeline { }`. RequestLogging sees the true
    /// wall-clock time of everything below it. Handed to `FlightWebModule`,
    /// which the composer aggregates middleware into.
    let middleware: [MiddlewareRegistration]

    /// `RateLimiter` comes from `FlightRateLimitModule`, matched by type in
    /// composition the way every other value a module takes is.
    init(graph: FlightGraph, limiter: RateLimiter) {
        self.graph = graph
        self.jobCoordinator = PostgresJobCoordinator(dataSource: graph.postgresDataSource)
        self.errorMapper = AppErrorMapping.mapper()
        self.middleware = MiddlewareRegistration.lane(
            .default,
            [
                RequestLogging(),
                // The key closure is required, and choosing it is the whole
                // decision. Here: the signed-in subject when there is one,
                // the real caller's address otherwise — so one noisy user
                // cannot spend everyone else's budget, and anonymous
                // traffic is bounded per caller rather than lumped
                // together as one.
                //
                // `clientAddress` is the raw socket peer unless
                // `web.trusted-proxies` names this connection as a trusted
                // reverse proxy, in which case it is resolved from
                // `X-Forwarded-For` instead — see Docs/client-address.md
                // for why that needs a policy at all. This demo runs with
                // no proxy configured, so it is the loopback address that
                // connects to it; a deployment behind one sets
                // `web.trusted-proxies` in its own environment's
                // flight-*.yaml, and nothing here changes.
                //
                // This runs after `Authentication`, which is why reading the
                // principal works: `AppModule` depends on
                // `FlightSecurityModule`, and lane order follows the module
                // graph. Reverse that dependency and this would silently see
                // `nil` on every request and limit the whole world as one
                // caller.
                RateLimiting(store: limiter.store, quota: .perMinute(300)) { context in
                    context.principal?.subject ?? context.clientAddress?.host ?? "unknown"
                },
            ])
            + MiddlewareRegistration.lane(
                "csrf",
                [
                    // `SessionController`'s sign-in and sign-out are the routes
                    // naming this lane (`pipelines: [.default, "csrf"]`): the
                    // two places in this demo an ambient cookie — or, for
                    // sign-in, a forged form post setting one — could be made
                    // to act. A lane of its own, rather than folding
                    // `CSRFProtection` into `.default`, keeps every
                    // bearer-token controller — which gets a session too,
                    // since `Sessions` is unconditionally in `.default`, but
                    // never a cookie carrying real authority — from having to
                    // present a token it has no page to have read one from.
                    CSRFProtection()
                ])
    }

    // The socket route itself is `SocketController`, declared with
    // `@WebSocketRoute`; the app's controllers become routes through the
    // generated `flightRoutes(graph)`, not a registration here.
}

@main
struct Main {
    static func main() async {
        // Configuration loads first (flight.yaml + FLIGHT_* env), then the
        // modules are composed in dependency order, every component is built
        // once, the ServiceGroup starts, and only then does request serving
        // begin — never against a half-built graph.
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
                DemoAuthModule.self,
                // Browser sign-in against the demo's own accounts. Swap for
                // `FlightOIDCSignInModule.self` and add a `security.oidc`
                // block to sign in through Keycloak or any OpenID Connect
                // provider instead; SessionController does not change.
                FlightPasswordSignInModule.self,
                DemoAccountsModule.self,
                DemoChannelsModule.self,
                AppModule.self,
                ActuatorModule.self,
            ],
            // Built by the plugin, in dependency order, from the list above:
            // `modules:` says which subsystems this application includes,
            // and this is how they are constructed: the build plugin writes a
            // composer that builds them in dependency order, which is what
            // lets a module take what it needs as initializer parameters.
            // It is required — there is no path without it.
            composedBy: flightComposeModules
        )
    }
}

/// The application's channels.
///
/// Their own module, for the same reason `DemoAuthModule` is: a socket route
/// injects `ChannelSockets`, which makes it a root of the component graph —
/// and a module that *provides* a graph root cannot also *take* the graph.
/// `AppModule` takes it, so the channels move here. The build refuses the
/// alternative by name, listing the cycle.
struct DemoChannelsModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }

    /// Everything a room channel needs, closed over rather than looked up.
    ///
    /// Taking the graph is legal here precisely because the graph does *not*
    /// depend on Channels: what a controller alone needs — the broadcaster,
    /// the socket stack — is passed to the route terminals instead of stored
    /// on the graph. Without that split this module could not exist.
    /// Inputs, not outputs — deliberately not stored. A stored `presence`
    /// would make this module *provide* `any Presence` alongside
    /// `FlightPresenceModule`, and the build refuses that ambiguity by name.
    /// What this module provides is `channels`.
    init(graph: FlightGraph, presence: any Presence) {
        let chat = graph.chatRepository
        let digests = graph.roomDigestService
        self.channels = [
            // The broadcaster arrives per join, in the `ChannelContext`:
            // Channels owns it and is built *from* this module, so it cannot
            // be a construction-time dependency without a cycle.
            ChannelRegistration("room:*", source: "DemoChannelsModule") { channel in
                RoomChannel(
                    broadcaster: channel.broadcaster,
                    presence: presence,
                    chat: chat,
                    digests: digests)
            }
        ]
    }

    init() {
        preconditionFailure(
            "DemoChannelsModule takes the component graph in init(graph:presence:).")
    }

    /// One declaration serves every room. Patterns are exact, prefix wildcard,
    /// or catch-all, and the most specific match wins; a malformed or
    /// duplicate pattern fails composition rather than a join.
    ///
    /// The composer collects `channels` from every module that declares any
    /// and hands them to `FlightChannelsModule`.
    let channels: [ChannelRegistration]
}

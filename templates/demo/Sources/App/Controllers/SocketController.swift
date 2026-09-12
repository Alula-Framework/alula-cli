import FlightChannels
import FlightCore
import FlightSecurityCore
import FlightWeb

/// The WebSocket entry point, as a route like any other.
///
/// `@WebSocketRoute` declares the upgrade route as an annotation — a thin
/// wrapper over a `.get` route with `kind: .upgrade(.webSocket)` — so the build
/// sees it. A socket route a module built by hand as a `RouteRegistration`
/// value would work too, but values assembled at run time can't be enumerated
/// at compile time, so the static route manifest the framework emits would not
/// include it. The declared form keeps it on the map.
///
/// The validator and the socket stack arrive by injection, the ordinary way a
/// controller gets a dependency.
@Controller
struct SocketController {

    /// The same validator `DemoAuthModule` provides for HTTP requests. Injected
    /// rather than pulled from the context, so the dependency is visible in the
    /// type rather than discovered when the closure runs.
    ///
    /// The marker acknowledges that this one is provided by a module — the
    /// bring-your-own-auth seam, `DemoAuthModule`'s `tokenValidator` value —
    /// rather than scanned from an annotation. Without it the build warns,
    /// correctly: the scanner can't see a module-provided value, so an unmarked
    /// @Inject of a type it never found as a @Component is usually a missing
    /// dependency that would fail composition.
    // flight:hand-registered
    @Inject var validator: any TokenValidator

    /// The channels stack, injected as one value. It used to be built with
    /// `ChannelSocketHandler(context:)`, which resolved the router, the bus
    /// and the channels configuration out of every upgrade request — three
    /// lookups of things the composition root wired at start-up.
    // flight:hand-registered
    @Inject var sockets: ChannelSockets

    /// The upgrade request is where identity is established — before the
    /// WebSocket exists, while there is still an HTTP response to fail with.
    /// Browsers cannot set headers on a WebSocket handshake, so the token
    /// arrives as a query parameter; returning an anonymous socket is
    /// deliberate, and every `join` in this app then rejects it.
    @WebSocketRoute("/socket")
    func socket(_ context: RequestContext) async throws -> ChannelSocketHandler {
        var principal: (any ChannelPrincipal)?
        if let token = context.request.queryParam("token") {
            principal = try? await validator.validate(token)
        }
        return sockets.handler(principal: principal)
    }
}

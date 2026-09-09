import FlightChannels
import FlightCore
import FlightSecurityCore
import FlightWeb

/// The WebSocket entry point, as a route like any other.
///
/// `@WebSocketRoute` rather than `container.registerChannelSocket("/socket")`
/// in the module body. The two do the same work — the convenience is a thin
/// wrapper over `registerRoute(.get, path, kind: .upgrade(.webSocket))` — but
/// only the declared form is visible to the build. A route registered from a
/// module body is arbitrary Swift, so nothing can enumerate it at compile
/// time, and the static route manifest the framework emits cannot include it.
///
/// It also removes a `context.resolve` from application code: the validator
/// arrives by injection, which is the ordinary way a controller gets a
/// dependency.
@Controller
struct SocketController {

    /// The same validator `AppModule` registers for HTTP requests. Injected
    /// rather than resolved from the context, so the dependency is visible in
    /// the type rather than discovered when the closure runs.
    ///
    /// The marker acknowledges that this one is registered by hand — the
    /// bring-your-own-auth seam in `AppModule.configure` — rather than
    /// scanned from an annotation. Without it the build warns, correctly:
    /// the scanner cannot see a `container.register` call, so an unmarked
    /// @Inject of a type it never found is usually a missing registration
    /// that would fail at startup.
    // flight:hand-registered
    @Inject var validator: any TokenValidator

    /// The channels stack, injected as one value. It used to be built with
    /// `ChannelSocketHandler(context:)`, which resolved the router, the bus
    /// and the channels configuration out of every upgrade request — three
    /// lookups of things the composition root wired at start-up.
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

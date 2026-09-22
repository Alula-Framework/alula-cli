import FlightCore
import FlightSecurityCore
import FlightWeb

/// Signing in with a cookie instead of a header.
///
/// Every other protected route in this demo reads `Authorization: Bearer
/// demo:<subject>[:<roles>]` on each request, which is what an API client
/// does. A browser does not: it presents a credential once and expects a
/// cookie to remember the answer. This controller is that once — it runs
/// the same `TokenValidator` the bearer path uses, stores the resulting
/// `Principal` in the session, and from then on `Authentication` finds it
/// there on every request that carries the cookie.
///
/// `DELETE /` — signing out — is this demo's one `CSRFProtection`-guarded
/// route: `"csrf"` names a lane `AppModule` fills with `CSRFProtection()`,
/// and `whoAmI` hands out the token every signed-in caller already has to
/// fetch to render a page at all. `POST /` — signing in — deliberately does
/// not carry the same guard: an anonymous visitor has no session yet to have
/// read a token from, and there is no server-rendered login page here to
/// embed one in ahead of time. That is "login CSRF," a real if narrower
/// attack (forcing a victim to authenticate as someone else, not to act as
/// themselves), and defending it needs a page or a dedicated token endpoint
/// this JSON-only demo does not have — see Docs/web.md in flight for the
/// pattern once it does.
///
/// Try it:
///
///     curl -si -X POST localhost:8080/session -H 'content-type: application/json' \
///          -d '{"token":"demo:ada:admin"}'                   # Set-Cookie: session=…
///     curl -s localhost:8080/session -H 'Cookie: session=…'  # {"subject":"ada","roles":[...],"csrfToken":"..."}
///     curl -si -X DELETE localhost:8080/session \
///          -H 'Cookie: session=…' -H 'X-CSRF-Token: …'       # the token whoAmI just answered with
@Controller("/session")
struct SessionController {
    /// The demo's validator, provided by `DemoAuthModule` as a value.
    @Inject var validator: any TokenValidator

    struct SignIn: Codable {
        let token: String
    }

    struct WhoAmI: Codable, ResponseEncodable {
        let subject: String
        let roles: [String]
        /// What `DELETE /` needs on `X-CSRF-Token`. Reading it here costs
        /// nothing extra: `whoAmI` already runs on an established,
        /// already-persisted session — unlike an anonymous route, there is
        /// no "a mere read now creates a store entry" cost to worry about.
        let csrfToken: String
    }

    /// Checks the credential once and remembers who it was. The session id
    /// changes here — `signIn` regenerates it — so an id handed out before
    /// the sign-in is not the one that is signed in afterwards.
    @PostRoute("/")
    func signIn(_ context: RequestContext, body: SignIn) async throws -> Response {
        let principal: Principal
        do {
            principal = try await validator.validate(body.token)
        } catch {
            // The reason stays in the log, as it does on the bearer path.
            context.logger.info("sign-in refused", metadata: ["reason": "\(error)"])
            throw HTTPError(.unauthorized, "Unauthorized")
        }
        try context.requireSession().signIn(principal)
        return .status(.noContent)
    }

    /// Who the cookie says this is. `.authenticated`, so an anonymous browser
    /// is refused before the handler — and the principal here came from the
    /// session, not from a header.
    @GetRoute("/", pipelines: [.authenticated])
    func whoAmI(_ context: RequestContext) throws -> WhoAmI {
        let principal = try context.requirePrincipal()
        return WhoAmI(
            subject: principal.subject, roles: principal.roles.sorted(),
            csrfToken: try context.requireSession().csrfToken())
    }

    /// Needs `X-CSRF-Token`, from the `whoAmI` this same browser already
    /// called to render anything worth showing a "sign out" button on.
    @DeleteRoute("/", pipelines: [.default, "csrf"])
    func signOut(_ context: RequestContext) throws -> Response {
        try context.requireSession().signOut()
        return .status(.noContent)
    }
}

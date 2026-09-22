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
/// Both halves are `CSRFProtection`-guarded: `"csrf"` names a lane
/// `AppModule` fills with `CSRFProtection()`. Signing *out* is the obvious
/// one. Signing *in* is the one people skip, and it is forgeable here: a
/// `Codable` body also accepts `application/x-www-form-urlencoded`, which a
/// plain HTML form on any site can submit with no preflight, and
/// `SameSite=Lax` limits which cookies that POST *sends*, not which its
/// response *sets*. Unguarded, a hostile page could sign a visitor into the
/// attacker's account ("login CSRF"). So `GET /csrf` hands an anonymous
/// browser a token first — which means it sets a cookie, the one cost of
/// guarding a login — and the token survives signing in, because `signIn`
/// regenerates the id and keeps the values.
///
/// Try it:
///
///     curl -si localhost:8080/session/csrf                   # Set-Cookie: session=…; {"csrfToken":"…"}
///     curl -si -X POST localhost:8080/session -H 'content-type: application/json' \
///          -H 'Cookie: session=…' -H 'X-CSRF-Token: …' \
///          -d '{"token":"demo:ada:admin"}'                   # Set-Cookie: session=… (a new id)
///     curl -s localhost:8080/session -H 'Cookie: session=…'  # {"subject":"ada","roles":[...],"csrfToken":"…"}
///     curl -si -X DELETE localhost:8080/session \
///          -H 'Cookie: session=…' -H 'X-CSRF-Token: …'       # the same token, still
@Controller("/session")
struct SessionController {
    /// The demo's validator, provided by `DemoAuthModule` as a value.
    @Inject var validator: any TokenValidator

    struct SignIn: Codable {
        let token: String
    }

    /// What `GET /csrf` answers: the token a browser sends back on
    /// `X-CSRF-Token` when it signs in.
    struct CSRFToken: Codable, ResponseEncodable {
        let csrfToken: String
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

    /// The token an anonymous browser needs before it can sign in. Minting it
    /// writes to the session, so this sets a cookie; nothing else anonymous
    /// in the demo does.
    @GetRoute("/csrf")
    func csrf(_ context: RequestContext) throws -> CSRFToken {
        CSRFToken(csrfToken: try context.requireSession().csrfToken())
    }

    /// Checks the credential once and remembers who it was. The session id
    /// changes here — `signIn` regenerates it — so an id handed out before
    /// the sign-in is not the one that is signed in afterwards. Needs
    /// `X-CSRF-Token` from `GET /csrf`.
    @PostRoute("/", pipelines: [.default, "csrf"])
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

import AlulaCore
import AlulaSecurityCore
import AlulaWeb

/// Signing in with a cookie instead of a header — written against
/// `SignInProvider`, so it does not know who checks the password.
///
/// Every other protected route in this demo reads `Authorization: Bearer
/// demo:<subject>[:<roles>]` on each request, which is what an API client
/// does. A browser does not: it signs in once and expects a cookie to
/// remember the answer. This controller is that once.
///
/// Today the provider is `AlulaPasswordSignInModule`'s, over the accounts
/// `DemoAccountsModule` holds. Swapping that one line in `Main.swift` for
/// `AlulaOIDCSignInModule.self`, plus a `security.oidc` block, moves this
/// demo onto Keycloak or any OpenID Connect provider — and nothing below
/// changes. `begin` answers with a form today and a redirect then; the
/// callback route is already here for it.
///
/// Sign-in and sign-out are both on the `"csrf"` lane. Sign-in is the one
/// people leave open, and it is forgeable: the password provider accepts a
/// form-encoded body, which a plain HTML form on any site can submit with no
/// preflight, and `SameSite=Lax` limits which cookies that POST *sends*, not
/// which its response *sets* — so an unguarded page could sign a visitor
/// into the attacker's account. `GET /csrf` hands an anonymous browser its
/// token first, which means it sets a cookie; the token survives signing
/// in, because `signIn` regenerates the id and keeps the values.
///
/// Try it:
///
///     curl -si localhost:8080/session/csrf                   # Set-Cookie: session=…; {"csrfToken":"…"}
///     curl -s localhost:8080/session/sign-in                 # {"fields":[{"name":"identifier",…},{"name":"password",…}]}
///     curl -si -X POST localhost:8080/session -H 'content-type: application/json' \
///          -H 'Cookie: session=…' -H 'X-CSRF-Token: …' \
///          -d '{"identifier":"ada@example.com","password":"correct horse"}'   # 204; Set-Cookie: a new id
///     curl -s localhost:8080/session -H 'Cookie: session=…'  # {"subject":"…","email":"ada@example.com",…}
///     curl -si -X DELETE localhost:8080/session \
///          -H 'Cookie: session=…' -H 'X-CSRF-Token: …'       # the same token, still
@Controller("/session")
struct SessionController {
    /// Whichever sign-in module is listed provides it.
    // alula:hand-registered — a value AlulaPasswordSignInModule (or
    // AlulaOIDCSignInModule) holds, not a scanned component.
    @Inject var provider: any SignInProvider

    /// What `GET /csrf` answers: the token a browser sends back on
    /// `X-CSRF-Token` when it signs in.
    struct CSRFToken: Codable, ResponseEncodable {
        let csrfToken: String
    }

    /// Who is signed in — the standard claims every provider emits, under
    /// the same names whichever one produced them.
    struct WhoAmI: Codable, ResponseEncodable {
        let subject: String
        let email: String?
        let name: String?
        let roles: [String]
        /// What `DELETE /` needs on `X-CSRF-Token`. Reading it here costs
        /// nothing extra: `whoAmI` already runs on an established session.
        let csrfToken: String
    }

    /// The token an anonymous browser needs before it can sign in. Minting it
    /// writes to the session, so this sets a cookie; nothing else anonymous
    /// in the demo does.
    @GetRoute("/csrf")
    func csrf(_ context: RequestContext) throws -> CSRFToken {
        CSRFToken(csrfToken: try context.requireSession().csrfToken())
    }

    /// What starting looks like: a form to show (password) or a redirect to
    /// follow (an external provider). A front end that handles both needs no
    /// change when the provider does.
    @GetRoute("/sign-in")
    func begin(_ context: RequestContext) async throws -> Response {
        try await provider.beginSignIn(context, returnTo: context.request.queryParam("return-to"))
            .response()
    }

    /// The password form posts here. `signIn` checks it and puts the
    /// principal in the session, regenerating the session id — so an id
    /// handed out before the sign-in is not the one signed in afterwards.
    @PostRoute("/", pipelines: [.default, "csrf"])
    func signIn(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    /// Where an external provider sends the browser back. Unused while the
    /// provider is the password one; present so switching is only the
    /// module list. A GET, so CSRF-exempt — the provider's `state` is what
    /// ties the callback to this browser's sign-in.
    @GetRoute("/callback")
    func callback(_ context: RequestContext) async throws -> Response {
        try await provider.signIn(context).response()
    }

    /// Who the cookie says this is. `.authenticated`, so an anonymous browser
    /// is refused before the handler.
    @GetRoute("/", pipelines: [.authenticated])
    func whoAmI(_ context: RequestContext) throws -> WhoAmI {
        let principal = try context.requirePrincipal()
        return WhoAmI(
            subject: principal.subject, email: principal.email, name: principal.name,
            roles: principal.roles.sorted(), csrfToken: try context.requireSession().csrfToken())
    }

    /// Signs out here, and at the provider too when it has a session of its
    /// own to end — a redirect then, a 204 now.
    @DeleteRoute("/", pipelines: [.default, "csrf"])
    func signOut(_ context: RequestContext) async throws -> Response {
        try await provider.signOut(context).response()
    }
}

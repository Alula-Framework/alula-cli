import AlulaCore
import AlulaSecurityCore
import AlulaWeb

/// The account routes. Written by `alula generate auth`.
///
/// Signing in and out stay where they are — the sign-in provider's routes.
/// These are everything around them:
///
///     GET  /account/csrf              the token the POSTs below carry on X-CSRF-Token
///     POST /account/register          {name, email, password}   → 202, whatever happened
///     POST /account/verify-email      {token}                   → 204
///     POST /account/forgot-password   {email}                   → 202, whatever happened
///     POST /account/reset-password    {token, password}         → 204
///     POST /account/password          {current, new}            → 204, signed in
///
/// The links in the emails point at your front end
/// (`auth.link-base-url` + `/verify-email?token=…`), which posts the token
/// here. See `AccountFlows` for what each flow takes care of.
@Controller("/account")
struct AccountController {
    @Inject var flows: AccountFlows

    struct CSRFToken: Codable, ResponseEncodable {
        let csrfToken: String
    }

    struct Register: Decodable, Validatable {
        let name: String
        let email: String
        let password: String

        func validate(_ v: inout Validation) {
            v.check("name", name, .notBlank, .length(max: 120))
            v.check("email", email, .email, .length(max: 254))
            v.check("password", password, .length(min: 12, max: 256))
        }
    }

    struct TokenBody: Decodable, Validatable {
        let token: String
        func validate(_ v: inout Validation) { v.check("token", token, .notBlank) }
    }

    struct ForgotPassword: Decodable, Validatable {
        let email: String
        func validate(_ v: inout Validation) { v.check("email", email, .email) }
    }

    struct ResetPassword: Decodable, Validatable {
        let token: String
        let password: String

        func validate(_ v: inout Validation) {
            v.check("token", token, .notBlank)
            v.check("password", password, .length(min: 12, max: 256))
        }
    }

    struct ChangePassword: Decodable, Validatable {
        let current: String
        let new: String

        func validate(_ v: inout Validation) {
            v.check("new", new, .length(min: 12, max: 256))
        }
    }

    @GetRoute("/csrf")
    func csrf(_ context: RequestContext) throws -> CSRFToken {
        CSRFToken(csrfToken: try context.requireSession().csrfToken())
    }

    @PostRoute("/register", pipelines: [.default, "accounts"])
    func register(_ context: RequestContext, body: Register) async throws -> Response {
        try await flows.register(
            name: body.name, email: body.email, password: body.password,
            clientAddress: context.clientAddress?.host)
        return .status(.accepted)
    }

    @PostRoute("/verify-email", pipelines: [.default, "accounts"])
    func verifyEmail(_ context: RequestContext, body: TokenBody) async throws -> Response {
        try await flows.verifyEmail(token: body.token)
        return .noContent
    }

    @PostRoute("/forgot-password", pipelines: [.default, "accounts"])
    func forgotPassword(_ context: RequestContext, body: ForgotPassword) async throws -> Response {
        try await flows.requestPasswordReset(
            email: body.email, clientAddress: context.clientAddress?.host)
        return .status(.accepted)
    }

    @PostRoute("/reset-password", pipelines: [.default, "accounts"])
    func resetPassword(_ context: RequestContext, body: ResetPassword) async throws -> Response {
        try await flows.resetPassword(token: body.token, newPassword: body.password)
        return .noContent
    }

    /// Keeps this browser signed in and ends every other session.
    @PostRoute("/password", pipelines: [.authenticated, "accounts"])
    func changePassword(_ context: RequestContext, body: ChangePassword) async throws -> Response {
        try await flows.changePassword(
            principal: try context.requirePrincipal(), current: body.current, new: body.new,
            keeping: try context.requireSession().id, clientAddress: context.clientAddress?.host)
        return .noContent
    }
}

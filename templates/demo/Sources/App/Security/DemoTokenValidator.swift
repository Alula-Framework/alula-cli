import AlulaCore
import AlulaSecurityCore
import Foundation

/// A `TokenValidator` the demo can run without an identity provider.
///
/// This is the **bring-your-own-auth seam**, and it is the whole point of the
/// file. Alula Security Core ships one generic `OIDCTokenValidator` that any
/// standards-compliant provider — Keycloak, Auth0, Okta, Entra, Descope — is
/// merely *configuration* of. Registering a different `(any TokenValidator)`
/// before `AlulaSecurityModule` replaces it wholesale; the module checks for
/// an existing registration and steps aside.
///
/// A real deployment deletes this file and sets `security.oidc.issuer` and
/// `security.oidc.audience` instead. It exists so the demo is runnable with
/// `curl` and no infrastructure — and so the seam has a worked example rather
/// than only prose.
///
/// The "tokens" it accepts are deliberately not JWTs and carry no signature.
/// Nothing here does cryptography, because pretending to would teach the
/// wrong lesson: real token verification is delegated to JWTKit, and the one
/// place this demo could plausibly hand-roll a security primitive is the one
/// place it refuses to.
///
///     Authorization: Bearer demo:ada:admin,author
///                          ^^^^ ^^^ ^^^^^^^^^^^^
///                          tag  sub roles (optional)
struct DemoTokenValidator: TokenValidator {
    /// The issuer stamped onto every `Principal` this produces, so the demo's
    /// principals are traceable to this validator and not mistaken for real
    /// federated identities.
    static let issuer = "alula-demo://insecure-local-validator"

    func validate(_ token: String) async throws -> Principal {
        let parts = token.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "demo" else {
            throw TokenValidationError(
                kind: .malformedToken,
                reason: "demo tokens look like 'demo:<subject>[:<role>,<role>]'")
        }
        let subject = String(parts[1])
        guard !subject.isEmpty else {
            throw TokenValidationError(
                kind: .missingRequiredClaim, reason: "demo token has an empty subject")
        }
        let roles: Set<String> =
            parts.count == 3
            ? Set(parts[2].split(separator: ",").map(String.init).filter { !$0.isEmpty })
            : []
        return Principal(
            subject: subject,
            issuer: Self.issuer,
            roles: roles,
            scopes: [],
            claims: ["demo": true]
        )
    }
}

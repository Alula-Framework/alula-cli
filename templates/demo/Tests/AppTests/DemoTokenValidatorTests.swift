import AlulaSecurityCore
import Testing

@testable import App

/// The bring-your-own-auth seam, tested as the contract it is.
///
/// These assertions are about `DemoTokenValidator` specifically, but the shape
/// is the point: a `TokenValidator` turns an opaque string into a `Principal`
/// or throws a typed reason, and everything above it — the middleware, the
/// handler guards, the WebSocket upgrade — is written against that contract
/// rather than against any particular provider.
@Suite("Demo token validator — the BYOA seam")
struct DemoTokenValidatorTests {

    @Test("a bare subject becomes a principal with no roles")
    func bareSubject() async throws {
        let principal = try await DemoTokenValidator().validate("demo:ada")
        #expect(principal.subject == "ada")
        #expect(principal.roles.isEmpty)
        // The issuer marks these as locally minted, so a demo principal can
        // never be mistaken for a federated one in a log.
        #expect(principal.issuer == DemoTokenValidator.issuer)
    }

    @Test("roles ride along after the second colon")
    func roles() async throws {
        let principal = try await DemoTokenValidator().validate("demo:ada:moderator,author")
        #expect(principal.subject == "ada")
        #expect(principal.roles == ["moderator", "author"])
        #expect(principal.hasRole("moderator"))
        #expect(!principal.hasRole("admin"))
    }

    @Test("a body containing colons does not leak into the subject")
    func subjectStopsAtTheFirstColon() async throws {
        // maxSplits: 2 means everything after the second colon is the role
        // list, so a role string with a colon in it cannot silently extend
        // the subject.
        let principal = try await DemoTokenValidator().validate("demo:ada:a:b")
        #expect(principal.subject == "ada")
    }

    @Test("tokens that are not demo tokens are rejected, not guessed at")
    func rejectsForeignTokens() async throws {
        let validator = DemoTokenValidator()
        for bad in ["", "ada", "bearer:ada", "demo:", "eyJhbGciOiJIUzI1NiJ9.e30.x"] {
            await #expect(throws: TokenValidationError.self) {
                try await validator.validate(bad)
            }
        }
    }

    @Test("an empty role list is empty, not a role named \"\"")
    func emptyRolesAreDropped() async throws {
        let principal = try await DemoTokenValidator().validate("demo:ada:")
        #expect(principal.roles.isEmpty)
    }
}

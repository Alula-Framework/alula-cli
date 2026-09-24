import AlulaCore
import AlulaDataPostgres
import AlulaSecurityCore
import AlulaWeb

/// Accounts in Postgres, for password sign-in and the flows around it.
/// Written by `alula generate auth`.
///
/// List it in `Main.swift` beside `AlulaPasswordSignInModule`, which takes
/// the `credentialStore` this provides:
///
/// ```swift
/// AlulaPasswordSignInModule.self,
/// AccountsModule.self,
/// ```
///
/// Reads `auth.link-base-url`, where the links in its emails point, and
/// `app.name` for their wording.
struct AccountsModule: AlulaModule {
    static var dependencies: [any AlulaModule.Type] {
        [AlulaSecurityModule.self, AlulaSessionsModule.self]
    }

    /// Matched by type to `AlulaPasswordSignInModule`'s `store:`.
    let credentialStore: any CredentialStore
    /// The same accounts, with the operations the flows need.
    let accounts: any AccountDirectory
    /// Verification and reset links, stored in `account_tokens`.
    let oneTimeTokens: OneTimeTokens
    let authSettings: AuthSettings

    /// The `accounts` lane: CSRF protection for the account routes, which a
    /// form on another site could otherwise post to. A browser reads its
    /// token from `GET /account/csrf` first.
    let middleware: [MiddlewareRegistration]

    init(configuration: Configuration, dataSource: PostgresDataSource) throws {
        let accounts = PostgresAccounts(pool: dataSource)
        self.credentialStore = accounts
        self.accounts = accounts
        self.oneTimeTokens = OneTimeTokens(store: PostgresAccountTokens(pool: dataSource))
        self.authSettings = AuthSettings(
            linkBase: try configuration.getIfPresent("auth.link-base-url") ?? "http://localhost:8080",
            appName: try configuration.getIfPresent("app.name") ?? "App")
        self.middleware = MiddlewareRegistration.lane("accounts", [CSRFProtection()])
    }

    init() {
        preconditionFailure("AccountsModule is built by alulaComposeModules.")
    }
}

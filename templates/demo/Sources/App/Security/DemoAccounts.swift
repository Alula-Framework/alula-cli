import AlulaCore
import AlulaSecurityCore

/// The accounts the demo's password sign-in checks against.
///
/// In memory, seeded at startup, so the demo runs with nothing to set up. A
/// real application implements `CredentialStore` over its own users table —
/// two methods, find by identifier and save a stronger hash — and provides
/// that here instead; see Docs/sign-in.md in alula. Subjects are opaque ids,
/// never the email address: when this application moves to an identity
/// provider, the subject is what every row keyed by user survives on.
///
/// Its own module for the same reason `DemoAuthModule` is: `SessionController`
/// injects the sign-in provider, which makes the provider — and so this store
/// behind it — a root of the component graph, and `AppModule` takes the graph.
struct DemoAccountsModule: AlulaModule {
    /// Matched by type to `AlulaPasswordSignInModule`'s `store:`.
    let credentialStore: any CredentialStore

    init(configuration: Configuration) throws {
        let store = InMemoryCredentialStore()
        let hasher = Argon2idHashing()
        store.insert(
            StoredCredential(
                subject: "1f0c2b1e-ada0-4c3e-9d8e-000000000001",
                passwordHash: try hasher.hash("correct horse"),
                roles: ["admin", "author"],
                email: "ada@example.com", emailVerified: true, name: "Ada Lovelace",
                preferredUsername: "ada"),
            identifiers: ["ada@example.com", "ada"])
        store.insert(
            StoredCredential(
                subject: "1f0c2b1e-ada0-4c3e-9d8e-000000000002",
                passwordHash: try hasher.hash("battery staple"),
                roles: ["author"],
                email: "grace@example.com", emailVerified: true, name: "Grace Hopper",
                preferredUsername: "grace"),
            identifiers: ["grace@example.com", "grace"])
        self.credentialStore = store
    }

    init() {
        preconditionFailure("DemoAccountsModule is built by alulaComposeModules.")
    }
}

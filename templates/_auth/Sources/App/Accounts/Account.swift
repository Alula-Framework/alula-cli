import AlulaDataPostgres
import AlulaSecurityCore
import AlulaWeb
import Foundation

/// One person who can sign in. Written by `alula generate auth`; it is yours
/// now — add columns in a migration and properties here.
@Entity("accounts")
struct Account: Sendable, Equatable {
    @ID var id: UUID
    /// Always lowercased.
    var email: String
    var name: String
    /// An Argon2id hash, or nil for an account with no password yet.
    @Column("password_hash") var passwordHash: String?
    @Column("email_verified") var emailVerified: Bool
    var disabled: Bool
    var roles: [String]
    @Column("created_at") var createdAt: Date
    @Column("updated_at") var updatedAt: Date

    /// What password sign-in needs to see.
    var credential: StoredCredential {
        StoredCredential(
            subject: id.uuidString.lowercased(), passwordHash: passwordHash,
            roles: Set(roles), isDisabled: disabled, email: email,
            emailVerified: emailVerified, name: name)
    }
}

/// The account operations the auth flows need. Postgres in the app
/// (`PostgresAccounts`), memory in tests.
protocol AccountDirectory: CredentialStore {
    func account(email: String) async throws -> Account?
    func account(id: UUID) async throws -> Account?
    /// Throws ``AccountExists`` when the address is taken.
    func create(email: String, name: String, passwordHash: String) async throws -> Account
    func markEmailVerified(id: UUID) async throws
    func setPasswordHash(_ hash: String, id: UUID) async throws
}

struct AccountExists: Error {}

/// Accounts in the `accounts` table.
struct PostgresAccounts: AccountDirectory {
    let pool: PostgresDataSource

    func account(email: String) async throws -> Account? {
        let email = email.lowercased()
        return try await pool.withRepo { repo in
            try await repo.one(Account.where { $0.email == email })
        }
    }

    func account(id: UUID) async throws -> Account? {
        try await pool.withRepo { repo in
            try await repo.one(Account.where { $0.id == id })
        }
    }

    func create(email: String, name: String, passwordHash: String) async throws -> Account {
        let now = Date()
        let account = Account(
            id: UUID(), email: email.lowercased(), name: name, passwordHash: passwordHash,
            emailVerified: false, disabled: false, roles: [], createdAt: now, updatedAt: now)
        do {
            return try await pool.withRepo { repo in try await repo.insert(account) }
        } catch {
            if try await self.account(email: email) != nil { throw AccountExists() }
            throw error
        }
    }

    func markEmailVerified(id: UUID) async throws {
        try await pool.withRepo { repo in
            _ = try await repo.execute(
                "UPDATE accounts SET email_verified = true, updated_at = now() WHERE id = \(id)")
        }
    }

    func setPasswordHash(_ hash: String, id: UUID) async throws {
        try await pool.withRepo { repo in
            _ = try await repo.execute(
                "UPDATE accounts SET password_hash = \(hash), updated_at = now() WHERE id = \(id)")
        }
    }

    // MARK: CredentialStore

    func credential(forIdentifier identifier: String) async throws -> StoredCredential? {
        try await account(email: identifier)?.credential
    }

    func updatePasswordHash(_ hash: String, forSubject subject: String) async throws {
        guard let id = UUID(uuidString: subject) else { return }
        try await setPasswordHash(hash, id: id)
    }
}

/// One-time tokens in the `account_tokens` table: durable, and shared by
/// every replica, which the in-memory store is not.
struct PostgresAccountTokens: OneTimeTokenStore {
    let pool: PostgresDataSource

    func put(_ key: String, _ record: Data, ttl: Duration) async throws {
        let expires = Date().addingTimeInterval(Double(ttl.components.seconds))
        try await pool.withRepo { repo in
            _ = try await repo.execute(
                """
                INSERT INTO account_tokens (key, record, expires_at) VALUES (\(key), \(record), \(expires))
                ON CONFLICT (key) DO UPDATE SET record = EXCLUDED.record, expires_at = EXCLUDED.expires_at
                """)
            // Expired rows are removed as new ones arrive; no job needed.
            try await repo.execute("DELETE FROM account_tokens WHERE expires_at < now()")
        }
    }

    /// Delete-and-return in one statement: one redemption per token, however
    /// many requests race with the same link.
    func take(_ key: String) async throws -> Data? {
        try await pool.withRepo { repo in
            let rows = try await repo.execute(
                "DELETE FROM account_tokens WHERE key = \(key) AND expires_at > now() RETURNING record")
            for try await record in rows.decode(Data.self) { return record }
            return nil
        }
    }
}

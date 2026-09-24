import AlulaMail
import AlulaMailTesting
import AlulaQueueTesting
import AlulaRateLimit
import AlulaSecurityCore
import AlulaWeb
import Foundation
import Synchronization
import Testing

@testable import App

/// The account flows over an in-memory directory: every email they send is
/// recorded, and the link in it followed. Written by `alula generate auth`.
@Suite("Account flows")
struct AccountFlowsTests {
    struct Fixture {
        let accounts = InMemoryAccounts()
        let transport = RecordingMailTransport()
        let sessions: InMemorySessionStore
        let harness: QueueTestHarness
        let flows: AccountFlows

        init() throws {
            let mailer = Mailer(transport: transport, defaultFrom: try MailAddress("app@example.com"))
            let limiter = RateLimiter(store: InMemoryRateLimitStore())
            sessions = InMemorySessionStore()
            harness = QueueTestHarness(handlers: [mailer.deliveryHandler])
            flows = AccountFlows(
                accounts: accounts,
                tokens: OneTimeTokens(store: InMemoryOneTimeTokenStore()),
                authenticator: PasswordAuthenticator(
                    store: accounts, issuer: "test", hasher: cheapHashing,
                    limiter: limiter),
                mailer: mailer, jobs: harness.queue,
                sessions: SessionRuntime(store: sessions, settings: try SessionSettings()),
                limiter: limiter,
                settings: AuthSettings(linkBase: "https://app.test", appName: "Test"))
        }

        /// Delivers what the flows queued and returns the token in the last
        /// email's link.
        func tokenFromLastEmail() async throws -> String {
            _ = await harness.drain()
            let text = try #require(transport.sent.last?.text)
            let link = try #require(text.split(separator: "\n").first { $0.contains("token=") })
            return String(link.split(separator: "token=").last!)
        }
    }

    @Test("registering, then following the emailed link, verifies the address")
    func registerAndVerify() async throws {
        let f = try Fixture()
        try await f.flows.register(
            name: "Ada", email: "Ada@Example.com", password: "correct horse battery",
            clientAddress: "10.0.0.1")
        let account = try #require(try await f.accounts.account(email: "ada@example.com"))
        #expect(!account.emailVerified)

        try await f.flows.verifyEmail(token: try await f.tokenFromLastEmail())
        #expect(try await f.accounts.account(email: "ada@example.com")?.emailVerified == true)
    }

    @Test("registering a taken address creates nothing and emails the owner instead")
    func registerTaken() async throws {
        let f = try Fixture()
        try await f.flows.register(
            name: "Ada", email: "ada@example.com", password: "correct horse battery",
            clientAddress: nil)
        _ = await f.harness.drain()
        try await f.flows.register(
            name: "Mallory", email: "ada@example.com", password: "something else entirely",
            clientAddress: nil)
        _ = await f.harness.drain()
        #expect(f.accounts.count == 1)
        #expect(f.transport.sent.last?.subject.contains("already have") == true)
    }

    @Test("a reset link works once, and ends the account's sessions")
    func resetPassword() async throws {
        let f = try Fixture()
        try await f.flows.register(
            name: "Ada", email: "ada@example.com", password: "correct horse battery",
            clientAddress: nil)
        _ = await f.harness.drain()
        let account = try #require(try await f.accounts.account(email: "ada@example.com"))
        let signedIn = SessionID.generate()
        try await f.sessions.save(
            signedIn, Data("{}".utf8), ttl: .seconds(60), owner: account.credential.subject)

        try await f.flows.requestPasswordReset(email: "ada@example.com", clientAddress: nil)
        let token = try await f.tokenFromLastEmail()
        try await f.flows.resetPassword(token: token, newPassword: "a whole new password")

        #expect(try await f.sessions.load(signedIn) == nil)
        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await f.flows.resetPassword(token: token, newPassword: "and another one again")
        }
    }

    @Test("changing the password voids reset links already sent")
    func resetLinkDiesWithOldPassword() async throws {
        let f = try Fixture()
        try await f.flows.register(
            name: "Ada", email: "ada@example.com", password: "correct horse battery",
            clientAddress: nil)
        _ = await f.harness.drain()
        try await f.flows.requestPasswordReset(email: "ada@example.com", clientAddress: nil)
        let token = try await f.tokenFromLastEmail()

        let account = try #require(try await f.accounts.account(email: "ada@example.com"))
        let principal = try await PasswordAuthenticator(
            store: f.accounts, issuer: "test", hasher: cheapHashing,
            limiter: RateLimiter(store: InMemoryRateLimitStore())
        ).authenticate(identifier: account.email, password: "correct horse battery", clientAddress: nil)
        try await f.flows.changePassword(
            principal: principal, current: "correct horse battery", new: "changed it myself",
            keeping: nil, clientAddress: nil)

        await #expect(throws: OneTimeTokenError.invalidOrExpired) {
            try await f.flows.resetPassword(token: token, newPassword: "the attacker's choice")
        }
    }

    @Test("asking to reset an unknown address sends nothing and says nothing")
    func resetUnknown() async throws {
        let f = try Fixture()
        try await f.flows.requestPasswordReset(email: "nobody@example.com", clientAddress: nil)
        _ = await f.harness.drain()
        #expect(f.transport.sent.isEmpty)
    }

    @Test("reset requests for one address are throttled")
    func throttled() async throws {
        let f = try Fixture()
        for _ in 0..<5 {
            try await f.flows.requestPasswordReset(email: "ada@example.com", clientAddress: nil)
        }
        await #expect(throws: HTTPError.self) {
            try await f.flows.requestPasswordReset(email: "ada@example.com", clientAddress: nil)
        }
    }
}

/// Real Argon2id, at a cost that keeps the suite fast. Never in the app.
let cheapHashing = Argon2idHashing(
    parameters: .init(timeCost: 1, memoryCost: 64, parallelism: 1))

/// An `AccountDirectory` in memory.
final class InMemoryAccounts: AccountDirectory, Sendable {
    private let rows = Mutex<[UUID: Account]>([:])

    var count: Int { rows.withLock { $0.count } }

    func account(email: String) async throws -> Account? {
        rows.withLock { $0.values.first { $0.email == email.lowercased() } }
    }

    func account(id: UUID) async throws -> Account? {
        rows.withLock { $0[id] }
    }

    func create(email: String, name: String, passwordHash: String) async throws -> Account {
        try rows.withLock { rows in
            guard !rows.values.contains(where: { $0.email == email.lowercased() }) else {
                throw AccountExists()
            }
            let account = Account(
                id: UUID(), email: email.lowercased(), name: name, passwordHash: passwordHash,
                emailVerified: false, disabled: false, roles: [], createdAt: Date(),
                updatedAt: Date())
            rows[account.id] = account
            return account
        }
    }

    func markEmailVerified(id: UUID) async throws {
        rows.withLock { $0[id]?.emailVerified = true }
    }

    func setPasswordHash(_ hash: String, id: UUID) async throws {
        rows.withLock { $0[id]?.passwordHash = hash }
    }

    func credential(forIdentifier identifier: String) async throws -> StoredCredential? {
        try await account(email: identifier)?.credential
    }

    func updatePasswordHash(_ hash: String, forSubject subject: String) async throws {
        guard let id = UUID(uuidString: subject) else { return }
        try await setPasswordHash(hash, id: id)
    }
}

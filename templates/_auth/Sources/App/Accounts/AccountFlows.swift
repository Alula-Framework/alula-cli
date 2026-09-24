import AlulaCore
import AlulaMail
import AlulaQueue
import AlulaRateLimit
import AlulaSecurityCore
import AlulaWeb
import Foundation

/// `auth.*`, read by `AccountsModule`.
struct AuthSettings: Sendable {
    /// Where the links in emails point: your front end's pages, which read
    /// the `token` and post it back.
    var linkBase: String
    var appName: String
}

/// Registration, email verification, password reset and password change.
/// Written by `alula generate auth`; yours to change.
///
/// What it takes care not to leak, and why:
/// - Registering and asking for a reset answer the same way whether or not
///   the address has an account, so neither can be used to find out who
///   does. A taken address gets an email saying so instead.
/// - A reset token is bound to the password hash it was issued against. The
///   first reset changes the hash, and every other outstanding token dies
///   with it.
/// - Resetting or changing a password ends the account's other sessions.
/// - The endpoints that send email are throttled per address and per client,
///   so they cannot be used to flood someone's inbox.
@Service
struct AccountFlows {
    @Inject var accounts: any AccountDirectory
    @Inject var tokens: OneTimeTokens
    @Inject var authenticator: PasswordAuthenticator
    @Inject var mailer: Mailer
    @Inject var jobs: JobQueue
    @Inject var sessions: SessionRuntime
    @Inject var limiter: RateLimiter
    @Inject var settings: AuthSettings

    func register(name: String, email: String, password: String, clientAddress: String?)
        async throws
    {
        let email = email.lowercased()
        try await throttle("register", email: email, clientAddress: clientAddress)
        let hash = try authenticator.hashNewPassword(password)
        do {
            let account = try await accounts.create(email: email, name: name, passwordHash: hash)
            try await sendVerification(to: account)
        } catch is AccountExists {
            try await mailer.sendLater(AuthMail.alreadyRegistered(email, settings: settings), via: jobs)
        }
    }

    func verifyEmail(token: String) async throws {
        let subject = try await tokens.redeem(token, purpose: .emailVerification) { subject in
            try await self.account(subject)?.email
        }
        guard let id = UUID(uuidString: subject) else { throw OneTimeTokenError.invalidOrExpired }
        try await accounts.markEmailVerified(id: id)
    }

    func requestPasswordReset(email: String, clientAddress: String?) async throws {
        let email = email.lowercased()
        try await throttle("reset", email: email, clientAddress: clientAddress)
        guard let account = try await accounts.account(email: email), !account.disabled else { return }
        let token = try await tokens.issue(
            for: account.credential.subject, purpose: .passwordReset, lifetime: .seconds(3600),
            binding: account.passwordHash ?? "")
        try await mailer.sendLater(
            AuthMail.resetPassword(account, token: token, settings: settings), via: jobs)
    }

    func resetPassword(token: String, newPassword: String) async throws {
        let subject = try await tokens.redeem(token, purpose: .passwordReset) { subject in
            try await self.account(subject).map { $0.passwordHash ?? "" }
        }
        guard let id = UUID(uuidString: subject) else { throw OneTimeTokenError.invalidOrExpired }
        try await accounts.setPasswordHash(try authenticator.hashNewPassword(newPassword), id: id)
        _ = try? await sessions.revokeSessions(ownedBy: subject)
    }

    /// Checks the current password the way sign-in does, throttling included.
    func changePassword(
        principal: Principal, current: String, new: String, keeping session: SessionID?,
        clientAddress: String?
    ) async throws {
        guard let email = principal.email else { throw PasswordAuthenticationError.invalidCredentials }
        _ = try await authenticator.authenticate(
            identifier: email, password: current, clientAddress: clientAddress)
        guard let id = UUID(uuidString: principal.subject) else {
            throw PasswordAuthenticationError.invalidCredentials
        }
        try await accounts.setPasswordHash(try authenticator.hashNewPassword(new), id: id)
        _ = try? await sessions.revokeSessions(ownedBy: principal.subject, keeping: session)
    }

    func sendVerification(to account: Account) async throws {
        let token = try await tokens.issue(
            for: account.credential.subject, purpose: .emailVerification, lifetime: .seconds(48 * 3600),
            binding: account.email)
        try await mailer.sendLater(
            AuthMail.verifyEmail(account, token: token, settings: settings), via: jobs)
    }

    private func account(_ subject: String) async throws -> Account? {
        guard let id = UUID(uuidString: subject) else { return nil }
        return try await accounts.account(id: id)
    }

    private func throttle(_ action: String, email: String, clientAddress: String?) async throws {
        let perAddress = try await limiter.consume("auth:\(action):\(email)", quota: .perHour(5))
        var allowed = perAddress.isAllowed
        if let clientAddress {
            allowed =
                try await limiter.consume("auth:\(action):ip:\(clientAddress)", quota: .perHour(30))
                .isAllowed && allowed
        }
        guard allowed else { throw HTTPError(.tooManyRequests, "Too many requests; try again later") }
    }
}

/// The emails the flows send. Plain text; add `html:` when you have a design.
enum AuthMail {
    static func verifyEmail(_ account: Account, token: String, settings: AuthSettings) throws
        -> MailMessage
    {
        MailMessage(
            to: [try MailAddress(account.email, name: account.name)],
            subject: "Confirm your email for \(settings.appName)",
            text: """
                Hello \(account.name),

                Confirm this address by opening:
                \(settings.linkBase)/verify-email?token=\(token)

                The link works for 48 hours. If you did not sign up, ignore this email.
                """)
    }

    static func resetPassword(_ account: Account, token: String, settings: AuthSettings) throws
        -> MailMessage
    {
        MailMessage(
            to: [try MailAddress(account.email, name: account.name)],
            subject: "Reset your \(settings.appName) password",
            text: """
                Hello \(account.name),

                Choose a new password here:
                \(settings.linkBase)/reset-password?token=\(token)

                The link works for one hour, once. If you did not ask for this, \
                ignore this email; your password has not changed.
                """)
    }

    static func alreadyRegistered(_ email: String, settings: AuthSettings) throws -> MailMessage {
        MailMessage(
            to: [try MailAddress(email)],
            subject: "You already have an account with \(settings.appName)",
            text: """
                Someone tried to register with this address, which already has an account.

                If it was you, sign in, or reset your password:
                \(settings.linkBase)/forgot-password

                If it was not, you can ignore this email.
                """)
    }
}

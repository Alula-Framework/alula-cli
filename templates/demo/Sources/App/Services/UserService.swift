import AlulaCore
import AlulaMail
import AlulaQueue
import AlulaDataPostgres
import Foundation

/// The business-logic layer between controllers and data access.
///
/// `@Inject` targets the existential `(any UserRepositoryProtocol)`
/// rather than the concrete `UserRepository` — the seam that makes this type
/// unit-testable. Nothing bridges that key by hand: the composition root
/// matches this demand against `UserRepository`'s conformance (its only
/// scanned conformer) and builds the service from it. Tests construct the
/// service directly with a fake repository — see `UserServiceTests.swift` /
/// `UserControllerTests.swift` for the two ends of the seam.
@Service
struct UserService {
    @Inject var repository: (any UserRepositoryProtocol)
    /// Mail goes through the queue: signing up neither waits on a mail
    /// server nor fails when one is down. See Docs/mail.md in alula.
    @Inject var mailer: Mailer
    @Inject var jobs: JobQueue

    func all() async throws -> [User] {
        try await repository.all()
    }

    func find(byID id: UUID) async throws -> User? {
        try await repository.find(byID: id)
    }

    func find(byEmail email: String) async throws -> User? {
        try await repository.find(byEmail: email)
    }

    /// The transaction boundary lives inside the repository method, where
    /// the statements it covers are — this just validates and forwards.
    func signup(name: String, email: String) async throws -> User {
        let changeset = Changeset(User.self)
            .change(\.name, name)
            .change(\.email, email)
            .validate(\.email, .email)
        guard changeset.isValid else { throw ChangesetValidationError(errors: changeset.errors) }
        try await repository.apply(changeset)
        let user = try await repository.find(byEmail: email)!
        try await mailer.sendLater(
            MailMessage(
                to: [try MailAddress(user.email, name: user.name)],
                subject: "Welcome to the Alula demo",
                text: "Hello \(user.name), your account is ready."),
            via: jobs)
        return user
    }

    func update(id: UUID, changeset: Changeset<User>) async throws -> User? {
        try await repository.apply(changeset)
        return try await repository.find(byID: id)
    }
}

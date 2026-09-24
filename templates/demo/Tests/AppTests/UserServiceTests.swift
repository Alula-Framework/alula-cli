import AlulaCore
import AlulaMail
import AlulaMailTesting
import AlulaQueueTesting
import AlulaWebTesting
import Foundation
import Testing
@testable import App

/// UserService with a fake repository underneath it.
///
/// The service is registered and resolved exactly as the application does it,
/// so its own wiring — scope, stereotype, injected properties — is under test
/// rather than bypassed. Only the repository is replaced.
@Suite("UserService — repository mocked")
struct UserServiceTests {
    private func makeService(repository: MockUserRepository) -> UserService {
        // The service under test, built with the fake the way the composer
        // builds it from the graph — the repository is injected by value.
        UserService(repository: repository, mailer: .testing, jobs: QueueTestHarness().queue)
    }

    @Test("find(byID:) returns the matching user from the mocked repository")
    func findByIDReturnsMatch() async throws {
        let ada = User(
            id: UUID(), name: "Ada", email: "ada@example.com",
            createdAt: Date(), updatedAt: Date())
        let found = try await makeService(
            repository: MockUserRepository(users: [ada])).find(byID: ada.id)

        #expect(found == ada)
    }

    @Test("find(byID:) returns nil when the mocked repository has no match")
    func findByIDReturnsNilWhenMissing() async throws {
        let found = try await makeService(
            repository: MockUserRepository()).find(byID: UUID())

        #expect(found == nil)
    }

    @Test("signing up queues a welcome email instead of sending it inline")
    func signupQueuesWelcomeMail() async throws {
        let transport = RecordingMailTransport()
        let mailer = Mailer(transport: transport, defaultFrom: try MailAddress("demo@example.com"))
        let harness = QueueTestHarness(handlers: [mailer.deliveryHandler])
        // The mock records changesets without applying them, so the user the
        // signup reads back is seeded.
        let ada = User(
            id: UUID(), name: "Ada", email: "ada@example.com",
            createdAt: Date(), updatedAt: Date())
        let service = UserService(
            repository: MockUserRepository(users: [ada]), mailer: mailer, jobs: harness.queue)

        let user = try await service.signup(name: "Ada", email: "ada@example.com")
        // Nothing is sent while the request is still running...
        #expect(transport.sent.isEmpty)
        // ...and the worker delivers it.
        #expect(await harness.drain() == [.completed])
        #expect(transport.sent.first?.to.first?.address == user.email)
        #expect(transport.sent.first?.subject == "Welcome to the Alula demo")
    }
}

extension Mailer {
    /// Records rather than sends; for tests that do not look at mail.
    static var testing: Mailer {
        Mailer(transport: RecordingMailTransport(), defaultFrom: try! MailAddress("demo@example.com"))
    }
}

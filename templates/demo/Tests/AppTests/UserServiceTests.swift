import AlulaCore
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
        UserService(repository: repository)
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
}

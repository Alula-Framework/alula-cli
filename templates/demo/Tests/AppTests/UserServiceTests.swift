import FlightCore
import FlightWebTesting
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
    private func makeContainer(repository: MockUserRepository) throws -> Container {
        try TestContainer.build {
            Components(UserService.self)
            FakeRepository(repository)
        }
    }

    @Test("find(byID:) returns the matching user from the mocked repository")
    func findByIDReturnsMatch() async throws {
        let ada = User(
            id: UUID(), name: "Ada", email: "ada@example.com",
            createdAt: Date(), updatedAt: Date())
        let container = try makeContainer(repository: MockUserRepository(users: [ada]))

        let found = try await container.resolve(UserService.self).find(byID: ada.id)

        #expect(found == ada)
    }

    @Test("find(byID:) returns nil when the mocked repository has no match")
    func findByIDReturnsNilWhenMissing() async throws {
        let container = try makeContainer(repository: MockUserRepository())

        let found = try await container.resolve(UserService.self).find(byID: UUID())

        #expect(found == nil)
    }
}

import Foundation
import FlightCore
import FlightWeb
import FlightDataCore

struct CreateUserRequest: Codable {
    let name: String
    let email: String
}

@Controller
struct UserController {
    @GetRoute("/users")
    func listUsers(_ context: RequestContext) async throws -> [User] {
        try await context.resolve(UserService.self).all()
    }

    @GetRoute("/user/:id")
    func getUser(_ context: RequestContext) async throws -> User {
        guard let id = context.pathParam("id").flatMap({ UUID(uuidString: $0) }) else {
            throw HTTPError(.badRequest, "user id must be a UUID")
        }
        guard let user = try await context.resolve(UserService.self).find(byID: id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        return user
    }

    /// `UserRepository.signup` writes the lobby announcement before the
    /// user, so a duplicate email has to roll the announcement back. The
    /// transaction that makes that true is inside `signup` itself —
    /// `repo.transaction { }` around both writes — so this handler has
    /// nothing to bind and nothing to remember.
    ///
    /// It used to have both: an ambient coordinator, bound by a middleware,
    /// which a handler could forget to bind. One that did shipped with every
    /// write landing and nothing rolling back, and the guarantee in
    /// `signup`'s own doc comment quietly false. A boundary you can see in
    /// the code that opens it cannot be forgotten somewhere else.
    @PostRoute("/user")
    func upsertUser(_ context: RequestContext, body: CreateUserRequest) async throws -> Response {
        context.logger.info("Creating user")
        let service = try context.resolve(UserService.self)

        if let user = try await service.find(byEmail: body.email) {
            let changeset = Changeset(original: user)
            .change(\.email, body.email)
            .change(\.name, body.name)
            .validate(\.email, .email)
            context.logger.info("Upserting user")
            guard changeset.isValid else { throw HTTPError(.badRequest, "Invalid User") }
            let updated = try await service.update(id: user.id, changeset: changeset)
            return try .json(updated)
        }

        let created = try await service.signup(name: body.name, email: body.email)
        return try .json(created)
    }

    @PostRoute("/chatUser")
    func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> Response {
        let service = try context.resolve(UserService.self)
        let user = try await service.signup(name: body.name, email: body.email)
        return try .json(user, status: .created)
    }
}

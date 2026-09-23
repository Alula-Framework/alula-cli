import AlulaCore
import AlulaDataCore
import AlulaWeb
import Foundation

struct CreateUserRequest: Codable {
    let name: String
    let email: String
}

/// CRUD over `users`.
///
/// Handlers stay thin: resolve, delegate, translate failures into status
/// codes. The controller is the only layer that should know what an HTTP
/// status is, and the repository is the only layer that should know SQL.
@Controller
struct UserController {

    /// The seam, not the concrete repository. Exactly one type in this
    /// target conforms to it, so the registration generator synthesizes the
    /// binding — nothing registers it by hand, and a test can register its
    /// own fake under the same key.
    @Inject var users: (any UserRepositoryProtocol)

    @GetRoute("/users")
    func list(_ context: RequestContext) async throws -> [User] {
        try await users.all()
    }

    /// `id: UUID` binds the `:id` segment, already parsed.
    ///
    /// The handler never sees a string. A request for `/users/not-a-uuid` is
    /// answered 400 before this body runs, naming the parameter and the type
    /// it wanted — so the only failure left here is the one that is actually
    /// about users: there is no such user.
    ///
    /// The macro checks the label against the path, so renaming one and not
    /// the other is a build error rather than a 500 at runtime.
    @GetRoute("/users/:id")
    func get(_ context: RequestContext, id: UUID) async throws -> User {
        guard let user = try await users.find(byID: id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        return user
    }

    @PostRoute("/users")
    func create(_ context: RequestContext, body: CreateUserRequest) async throws -> Response {
        // Validation runs before any SQL does: a changeset collects the
        // changes, checks them, and only a valid one reaches the database.
        let changeset = Changeset(User.self)
            .change(\.name, body.name)
            .change(\.email, body.email)
            .validate(\.email, .email)
        guard changeset.isValid else {
            throw HTTPError(.badRequest, "invalid user: \(changeset.errors)")
        }
        guard try await users.find(byEmail: body.email) == nil else {
            throw HTTPError(.conflict, "that email is already registered")
        }
        return try .json(await users.create(name: body.name, email: body.email), status: .created)
    }
}

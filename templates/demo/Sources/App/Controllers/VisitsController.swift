import AlulaCore
import AlulaWeb

/// The room a browser last opened, remembered in its session.
///
/// This is the demo's one use of sessions, and it is deliberately small:
/// state that belongs to a *browser* rather than to a user — no login, no
/// account, nothing the bearer-token routes know about. A client that opens
/// a room tells the server so, and the next visit from the same browser can
/// ask where it left off.
///
/// What it shows: `context.requireSession()` is the whole API surface a
/// handler needs; nothing is stored, and no cookie is set, until the first
/// write; and a `Codable` value goes in and comes out unchanged.
@Controller("/visits")
struct VisitsController {

    /// The answer to "where did I leave off". `slug` is `nil` for a browser
    /// that has never told us — a 200 with nothing in it, because "nowhere
    /// yet" is an ordinary answer rather than an error.
    struct LastVisit: Codable, ResponseEncodable {
        let slug: String?
    }

    @GetRoute("/last")
    func last(_ context: RequestContext) throws -> LastVisit {
        LastVisit(slug: try context.requireSession().get("last-room", as: String.self))
    }

    /// Records a visit. Setting the same slug twice costs no store write —
    /// the session notices the bytes did not change.
    @PostRoute("/:slug")
    func visit(_ context: RequestContext, slug: String) throws -> LastVisit {
        try context.requireSession().set("last-room", slug)
        return LastVisit(slug: slug)
    }

    /// Forgets everything this browser told us: the store entry is deleted
    /// and the cookie expired.
    @DeleteRoute("/")
    func forget(_ context: RequestContext) throws -> Response {
        try context.requireSession().destroy()
        return .status(.noContent)
    }
}

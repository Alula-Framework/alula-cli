import AlulaCore
import AlulaDataPostgres
import AlulaWeb

/// One place where the error vocabularies this application *uses* but does
/// not own become HTTP.
///
/// `HTTPErrorRepresentable` covers the errors you can conform; everything
/// else renders as an opaque 500. That leaves exactly the types an
/// application actually meets — `DataSourceError`, `HangarError`,
/// `ChangesetValidationError` — with no HTTP shape, and they cannot be
/// conformed here: they belong to other packages, and the packages below
/// `AlulaWeb` deliberately do not depend on it. A middleware cannot help
/// either, because a handler's error is rendered by the router *inside* the
/// chain — by the time middleware sees anything it is a finished 500.
///
/// So the application registers one mapper and says what it knows. Returning
/// `nil` declines: that error follows the ordinary path.
enum AppErrorMapping {
    static func mapper() -> ErrorMapper {
        ErrorMapper { error in
            switch error {
            case DataSourceError.poolExhausted:
                // Saturation, not a bug. A 500 tells the client the opposite
                // of the truth, which is "come back in a moment".
                return .init(
                    .serviceUnavailable, "The service is busy. Retry shortly.",
                    headers: [.retryAfter: "1"])

            case let invalid as ChangesetValidationError:
                return .init(.unprocessableContent, invalid.description)

            case HangarError.unknownFilterField(_, let field):
                return .init(.badRequest, "unknown filter field '\(field)'")

            case HangarError.invalidFilterValue(_, let field):
                return .init(.badRequest, "filter '\(field)' has the wrong type for its column")

            case ChatError.noSuchRoom(let id):
                return .init(.notFound, "no room \(id)")

            case ChatError.multiStepFailed(let step, let underlying):
                // A `Multi` failure is a value carrying the step that broke,
                // so the mapper can unwrap it and map what is inside.
                if let inner = mapper().map(underlying) {
                    return .init(inner.status, "step '\(step)': \(inner.message)", headers: inner.headers)
                }
                return .init(.internalServerError, "step '\(step)' failed")

            default:
                return nil
            }
        }
    }
}

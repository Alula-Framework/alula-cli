import AlulaCore
import AlulaWeb

/// Logs the method and path of every request as it arrives.
@Middleware
struct RequestLogging: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        context.logger.info("→ \(context.request.method.rawValue) \(context.request.path)")
        return try await next(context)
    }
}

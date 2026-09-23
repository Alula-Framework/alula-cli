import AlulaCore
import AlulaRateLimit
import AlulaRateLimitTesting
import AlulaSecurityCore
import AlulaWeb
import AlulaWebTesting
import HTTPTypes
import Testing

@testable import App

/// The demo limits by signed-in subject, falling back to the path. This
/// suite pins the part that is easy to get wrong: that two callers really do
/// have separate budgets, and that the limit is enforced rather than merely
/// configured.
@Suite("Rate limiting")
struct RateLimitingTests {
    private let store = RecordingRateLimitStore()

    /// The demo's own key rule, with a quota small enough to reach in a test.
    private func client(quota: RateLimitQuota = .perMinute(2)) throws -> TestClient {
        let validator: any TokenValidator = DemoTokenValidator()
        let security = AlulaSecurityModule(validator: validator)
        let limiting = RateLimiting(store: store, quota: quota) { context in
            context.principal?.subject ?? context.clientAddress?.host ?? "unknown"
        }
        // A route of this suite's own rather than a controller: what is
        // under test is the lane, and borrowing a controller would couple
        // this to whatever that controller happens to inject.
        let route = RouteRegistration(method: .get, path: "/health", source: "test") { _ in
            .text("ok")
        }
        return try TestClient(
            routes: [route],
            middleware: security.middleware
                + MiddlewareRegistration.lane(.default, [limiting]))
    }

    private func authorization(_ subject: String) -> HTTPFields {
        [.authorization: "Bearer demo:\(subject)"]
    }

    @Test("a caller over the quota is refused with a Retry-After")
    func refusesOverTheQuota() async throws {
        let client = try client()
        for _ in 0..<2 {
            #expect(await client.get("/health", headers: authorization("ada")).status == .ok)
        }
        let denied = await client.get("/health", headers: authorization("ada"))
        #expect(denied.status == .tooManyRequests)
        #expect(denied.header("retry-after") != nil)
        #expect(denied.header("x-ratelimit-remaining") == "0")
    }

    @Test("one noisy caller does not spend another's budget")
    func budgetsAreSeparate() async throws {
        let client = try client()
        for _ in 0..<3 { _ = await client.get("/health", headers: authorization("ada")) }
        #expect(
            await client.get("/health", headers: authorization("grace")).status == .ok,
            "grace has her own budget, because the key is the subject")
        #expect(store.callCount(for: "ada") == 3)
        #expect(store.callCount(for: "grace") == 1)
    }

    @Test("anonymous callers are keyed by their real address, not lumped into one bucket")
    func anonymousKeyedByAddress() async throws {
        let client = try client()
        _ = await client.execute(
            Request(method: .get, path: "/health", remoteAddress: PeerAddress(host: "203.0.113.9")))
        #expect(store.consumed.last?.key == "203.0.113.9")

        for _ in 0..<2 {
            _ = await client.execute(
                Request(method: .get, path: "/health", remoteAddress: PeerAddress(host: "203.0.113.20")))
        }
        #expect(
            await client.execute(
                Request(method: .get, path: "/health", remoteAddress: PeerAddress(host: "203.0.113.20"))
            ).status == .tooManyRequests,
            "the second anonymous caller reached its own limit — the first one's budget was untouched")
        #expect(
            await client.execute(
                Request(method: .get, path: "/health", remoteAddress: PeerAddress(host: "203.0.113.9"))
            ).status == .ok,
            "and still has its own budget left"
        )
    }

    @Test("an anonymous caller with no real socket behind it falls back to the unknown bucket")
    func noRemoteAddressFallsBack() async throws {
        // `TestClient.get` builds a `Request` with no `remoteAddress`, the
        // same shape a hand-built request in a snippet has. The key closure
        // still has to answer something.
        let client = try client()
        _ = await client.get("/health")
        #expect(store.consumed.last?.key == "unknown")
    }

    @Test("the quota replenishes")
    func replenishes() async throws {
        let client = try client()
        for _ in 0..<2 { _ = await client.get("/health", headers: authorization("ada")) }
        #expect(await client.get("/health", headers: authorization("ada")).status == .tooManyRequests)
        store.advance(by: .seconds(60))
        #expect(await client.get("/health", headers: authorization("ada")).status == .ok)
    }
}

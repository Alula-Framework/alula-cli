import FlightCache
import FlightCore
import Foundation

/// The read-heavy side of the chat app, cached.
///
/// `activity` and `headlines` are the two genuinely expensive queries in this
/// demo — a GROUP BY … HAVING over every message, and a DISTINCT ON across
/// every room. They are also the two most likely to be polled by a dashboard
/// on a timer, which is exactly the shape a cache is for: expensive to
/// compute, cheap to reuse, tolerant of being a few seconds stale.
///
/// `@Cacheable` expands **into the method body** rather than wrapping the type
/// in a proxy. That is the difference that matters versus Spring's version:
/// a call from one method of this type to another still goes through the
/// cache, because there is no proxy to bypass. The Spring footgun cannot
/// occur here.
///
/// The cache is coalescing: if fifty requests miss the same key at once, one
/// of them computes and the other forty-nine wait for that result instead of
/// stampeding the database.
@Service
struct RoomDigestService: DigestInvalidating, DigestReading {
    /// The repository itself. It used to be a *gateway* around it: a
    /// `.scoped` repository could not be captured by anything that outlives a
    /// request, so a singleton held a container instead and opened a scope
    /// per call. Repositories hold the pool now and lease per operation, so
    /// the indirection has nothing left to do — a long-lived service can hold
    /// one directly.
    @Inject var chat: ChatRepository

    /// Cached per `minimumMessages` — the argument is part of the key, so
    /// `?min=3` and `?min=10` are different entries rather than one poisoning
    /// the other.
    @Cacheable(namespace: "room_digest", ttl: .seconds(30))
    func activity(minimumMessages: Int) async throws -> [RoomActivity] {
        try await chat.activity(minimumMessages: minimumMessages)
    }

    @Cacheable(namespace: "room_digest", ttl: .seconds(30))
    func headlines() async throws -> [RoomHeadline] {
        try await chat.headlines()
    }

    /// Called whenever a message lands, from either the REST or the WebSocket
    /// path. Both digests are derived from the message table, so a new message
    /// invalidates the whole namespace rather than trying to work out which
    /// `minimumMessages` buckets a single row could have moved.
    ///
    /// A 30-second TTL would eventually do this on its own. Evicting on write
    /// is what makes "post a message, reload the dashboard, see it" true
    /// immediately — the property a user would otherwise report as a bug.
    @CacheEvict(namespace: "room_digest", allEntries: true)
    func messagesChanged() async {}
}

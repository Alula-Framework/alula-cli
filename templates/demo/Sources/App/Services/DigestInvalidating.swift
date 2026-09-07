import Foundation

/// The one thing `RoomChannel` needs from `RoomDigestService`: a way to say
/// "the message table changed, the derived digests are stale."
///
/// Same seam as `RoomStore`, for the same reason — `RoomDigestService` carries
/// an `@Inject`ed repository and a live cache, so depending on it concretely
/// would drag both into every test of the real-time path.
protocol DigestInvalidating: Sendable {
    func messagesChanged() async throws
}

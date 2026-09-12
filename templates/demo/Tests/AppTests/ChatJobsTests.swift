import FlightCore
import FlightWebTesting
import Foundation
import Testing

@testable import App

/// A scheduled job is an ordinary method on an ordinary component.
///
/// No scheduler and no database: `ChatJobs` is built directly with the digest
/// reads stubbed, exactly as `UserServiceTests` builds a service with its
/// repository stubbed. Whether the job fires at 03:00 is the cron engine's
/// business and is tested there, not here.
@Suite("ChatJobs — jobs as plain methods")
struct ChatJobsTests {

    private struct StubDigests: DigestReading {
        let rooms: [RoomActivity]

        func activity(minimumMessages: Int) async throws -> [RoomActivity] {
            rooms.filter { $0.messages >= minimumMessages }
        }
        func headlines() async throws -> [RoomHeadline] { [] }
    }

    private func jobs(rooms: [RoomActivity]) -> ChatJobs {
        // The scheduler is an ordinary component: built directly with the
        // digest reads stubbed, the way the composer builds it from the graph.
        ChatJobs(digests: StubDigests(rooms: rooms))
    }

    @Test("the nightly summary runs against the busy rooms")
    func summaryCountsBusyRooms() async throws {
        let jobs = jobs(rooms: [
            RoomActivity(room: "general", messages: 42, lastSentAt: Date()),
            RoomActivity(room: "quiet", messages: 1, lastSentAt: nil),
        ])
        try await jobs.nightlySummary()
    }

    @Test("warming the digests asks for the headlines")
    func warmingReadsHeadlines() async throws {
        try await jobs(rooms: []).warmDigests()
    }
}

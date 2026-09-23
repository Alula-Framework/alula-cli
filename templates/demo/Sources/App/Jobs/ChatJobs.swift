import AlulaCore
import AlulaScheduler
import Foundation

/// Scheduled work, as methods.
///
/// A `@Scheduler` type is an ordinary component — it injects what it needs
/// the same way a controller or a service does, and nothing registers it by
/// hand. The build plugin finds it.
///
/// The two jobs here are deliberately the two *different* kinds, because the
/// difference is the only thing about scheduling that is genuinely hard.
@Scheduler
struct ChatJobs {
    @Inject var digests: (any DigestReading)

    /// Runs once. Not once per server — once.
    ///
    /// On this demo that distinction is invisible, because there is one
    /// server. It stops being invisible the moment there are two: a summary
    /// that emails, bills, or writes a report must not do it twice, and the
    /// default is `once` precisely so the safe behaviour is what you get
    /// without thinking about it.
    ///
    /// Running once across several servers needs a `JobCoordinator` —
    /// `AlulaSchedulerPostgres` provides one. Without it the scheduler warns
    /// at startup rather than silently running this on every server, which is
    /// the kind of failure you would otherwise discover from the data.
    @Scheduled("0 0 3 * * *", timeZone: "UTC")
    func nightlySummary() async throws {
        let busy = try await digests.activity(minimumMessages: 10)
        // A real deployment would email or archive this. Logging keeps the
        // demo honest about what it actually does.
        print("nightly summary: \(busy.count) active room(s)")
    }

    /// Runs on every server, every time.
    ///
    /// The opposite case, and the reason `onEveryNode` exists. The demo's
    /// cache is in-memory, so it is *per process*: warming it on one server
    /// leaves every other server cold. This is work that is per-process by
    /// nature, and saying so is the whole distinction.
    ///
    /// Swap `AlulaCacheModule` for the Valkey-backed one and this becomes
    /// the wrong annotation — a shared cache only needs warming once. Where
    /// the state lives is what decides which of the two a job is.
    @Scheduled(every: .minutes(1), initialDelay: .seconds(5), onEveryNode: true)
    func warmDigests() async throws {
        _ = try await digests.headlines()
    }
}

import FlightCore
import FlightWeb

/// The one route this tier ships, so there is something to curl before you
/// have written anything.
///
/// `@Controller` registers the type and its routes at build time; there is no
/// runtime route table to mutate and no registration call to forget.
@Controller
struct HealthController {

    /// Reads a key from `flight.yaml`. With no `default:`, the build plugin
    /// verifies the key exists — misspell it and the build fails, naming it.
    @ConfigValue("app.name") var appName: String

    @GetRoute("/")
    func index(_ context: RequestContext) -> String {
        "\(appName) is flying"
    }

    /// A path parameter, bound by name and already the right type. There is
    /// no ceremony: the route pattern and the handler are checked against
    /// each other when this compiles, so `:word` and `word:` cannot drift
    /// apart, and a segment that does not parse is a 400 the handler never
    /// has to write.
    @GetRoute("/echo/:word")
    func echo(_ context: RequestContext, word: String) async throws -> String {
        "you said: \(word)"
    }
}

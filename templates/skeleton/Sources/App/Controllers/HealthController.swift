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
}

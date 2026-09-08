import FlightActuator
import FlightCore
import FlightTransport
import FlightWeb

/// Your application's module: one place that says what this app is made of.
///
/// `flightRegisterAll` is generated at build time from everything the
/// registration plugin found in this target — every `@Controller`,
/// `@Service`, `@Repository`, and `@Component`. Adding a controller does not
/// mean editing this file.
struct AppModule: FlightModule {
    /// Modules that must be configured before this one. The list is a DAG
    /// resolved once at bootstrap, so ordering is checked rather than hoped
    /// for.
    static var dependencies: [any FlightModule.Type] { [] }


    /// Every component, already built by the composition root. It used to be
    /// constructed from the container at `freeze()`; the graph's roots are
    /// things modules provide, so the place that assembles the modules is the
    /// place that can build it.
    let graph: FlightGraph

    /// This module takes the graph, so it cannot be built from its type.
    static var isTypeConstructible: Bool { false }

    init(graph: FlightGraph) { self.graph = graph }

    init() {
        preconditionFailure(
            "AppModule takes the component graph in init(graph:), so it cannot be instantiated "
                + "from its type. `composedBy: flightComposeModules` builds the graph and passes "
                + "it — Main.swift already does that.")
    }

    func configure(_ container: Container) throws {
        try flightRegisterAll(container, graph: graph)
    }
}

@main
struct Main {
    static func main() async {
        // Configuration loads first, then the container is built, the module
        // DAG configures, the container freezes, and only then does the
        // server start accepting requests. Nothing serves traffic against a
        // half-registered container.
        //
        // `Flight.run` rather than `main() async throws`: an error escaping
        // `main` is reported by the Swift runtime as "Fatal error: Error
        // raised at top level" followed by a register dump and a backtrace —
        // which is what a new project sees when Postgres is not running or
        // the port is already bound. `run` prints the reason and exits 1.
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [
                FlightWebModule<FlightTransport>.self,
                AppModule.self,
                ActuatorModule.self,
            ],
            // Built by the plugin, in dependency order, from the list above:
            // `modules:` says which subsystems this application includes,
            // and this is how they are constructed. Without it Flight
            // instantiates each from its type, which is why a module would
            // have to be constructible with no arguments.
            composedBy: flightComposeModules
        )
    }
}

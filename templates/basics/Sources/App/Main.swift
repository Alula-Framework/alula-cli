import FlightActuator
import FlightCore
import FlightDataPostgres
import FlightTransport
import FlightWeb

/// Your application's module: one place that says what this app is made of.
///
/// It declares the subsystems this app is built on. Everything else — every
/// `@Controller`, `@Service`, `@Repository`, and `@Component` the registration
/// plugin scans, including the binding from `(any UserRepositoryProtocol)` to
/// its one conformer — is wired by the generated composition root, so adding a
/// controller does not mean editing this file.
struct AppModule: FlightModule {
    /// Modules that must be built before this one. The list is a DAG resolved
    /// once at bootstrap, so ordering is checked rather than hoped for.
    static var dependencies: [any FlightModule.Type] {
        [PostgresDataModule<PrimaryDataSource>.self]
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

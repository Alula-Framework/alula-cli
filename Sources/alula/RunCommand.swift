import ArgumentParser
import Foundation

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run one of the application's own commands.",
        discussion: """
            Builds the app, then runs it with the command instead of serving. \
            The command runs with the app as composed and its infrastructure \
            (database pools, buses) started, but no HTTP server, scheduler or \
            queue workers.

              alula run commands                 list them
              alula run prune-visits             run one
              alula run import-users users.csv   with arguments

            Commands are declared by modules: `commands: [CommandRegistration]`.
            """
    )

    @Option(help: "The executable product. Default: the package's only one besides `migrate`.")
    var product: String?

    @Argument(parsing: .captureForPassthrough, help: "The command and its arguments.")
    var arguments: [String] = []

    func run() throws {
        let project = try Project.locate()
        let product = try self.product ?? Dev.defaultProduct(in: project.root)
        guard Dev.build(product, in: project.root) else { throw CLIError.delegateFailed(1) }
        let executable = try Dev.binPath(in: project.root).appendingPathComponent(product)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments.isEmpty ? ["commands"] : arguments
        process.currentDirectoryURL = project.root
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExitCode(process.terminationStatus)
        }
    }
}

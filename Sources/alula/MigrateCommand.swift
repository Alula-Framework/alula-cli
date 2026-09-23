import ArgumentParser
import Foundation

struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Run this project's migrations.",
        discussion: """
            Every argument is passed through to the project's migrate \
            executable, so the full command set is available:

              alula migrate                    apply all pending migrations
              alula migrate status             what is applied, what is pending
              alula migrate status --json      the same, machine-readable
              alula migrate create AddPosts    write a new timestamped migration
              alula migrate rollback           revert the last migration
              alula migrate rollback --steps 3
              alula migrate rollback --to 20260101000000
              alula migrate repair             re-checksum an edited migration
              alula migrate --dry-run          print the SQL without running it
              alula migrate --help             the full option list

            Migrations are Swift types in your package, discovered at build \
            time, so running them means building your project — a globally \
            installed binary cannot know what `CreateUsers.up(_:)` does. This \
            command builds and runs `migrate` for you.

            The connection URL comes from --database-url, then \
            $ALULA_DATABASE_URL, then $DATABASE_URL.

            `alula migrate init` is handled here rather than passed through: \
            it adds the migration targets to a project that has none.
            """
    )

    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Arguments for the migrate tool.", valueName: "arguments"))
    var arguments: [String] = []

    func run() async throws {
        let project = try Project.locate()

        // Handled here, because a project without the migrate target cannot
        // run anything — including a command whose job is to add it.
        if arguments.first == "init" {
            try MigrateInit(project: project).run()
            return
        }

        guard project.hasMigrateExecutable else {
            throw CLIError.noMigrateExecutable(project.root.path)
        }

        // Delegating rather than reimplementing: the migrate tool owns its own
        // command surface, and forwarding verbatim means a flag added there
        // works here with no change. There is nothing to keep in sync.
        let status = try Self.runSwift(
            ["run", "--package-path", project.root.path, "migrate"] + arguments,
            in: project.root)
        if status != 0 { throw CLIError.delegateFailed(status) }
    }

    /// Runs `swift` with the child sharing this process's stdio, so the
    /// migrate tool's output and prompts reach the terminal unchanged.
    static func runSwift(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

import ArgumentParser

@main
struct Alula: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "alula",
        abstract: "Scaffolding and tooling for Alula applications.",
        version: "0.1.0",
        subcommands: [New.self, Migrate.self, Routes.self, Dev.self, Generate.self]
    )
}

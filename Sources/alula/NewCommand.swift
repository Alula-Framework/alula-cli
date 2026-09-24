import ArgumentParser
import Foundation

struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new Alula project.",
        discussion: """
            Templates are complete, working projects — each one builds and passes \
            its tests before it ships in this binary. The tier decides how much is \
            already wired up:

              skeleton   configuration, dependency injection, HTTP, health endpoints
              basics     + entities, migrations, a repository, CRUD over Postgres
              demo       + PubSub, Channels, Presence, caching, authentication

            Start from skeleton unless you know you want the others; every tier's \
            files are a subset of the next one's, so moving up later is additive.
            """
    )

    @Argument(help: "The project name. Used as the Swift target and module name.")
    var name: String

    @Option(name: .shortAndLong, help: "Which template: skeleton, basics, or demo.")
    var tier: String = "skeleton"

    @Option(help: "Where to create it. Defaults to ./<name>.")
    var path: String?

    @Option(
        name: .customLong("with"),
        help: """
            Comma-separated capabilities to enable: postgres, valkey, security. \
            Defaults to what the tier needs — basics and demo get postgres, \
            demo also gets security. Naming any replaces that default.
            """)
    var capabilities: String?

    @Flag(help: "Write into the destination even if it already exists.")
    var force: Bool = false

    func run() async throws {
        let project = try ProjectName(name)

        guard EmbeddedTemplates.tiers.contains(tier), let template = EmbeddedTemplates.files[tier]
        else {
            throw CLIError.unknownTier(tier, available: EmbeddedTemplates.tiers)
        }

        let destination = URL(
            fileURLWithPath: path ?? project.value,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL

        if FileManager.default.fileExists(atPath: destination.path), !force {
            throw CLIError.destinationExists(destination.path)
        }

        // What the tier implies, unless --with says otherwise.
        let requested: Set<Capability>
        if let capabilities {
            requested = try Capability.parse(capabilities)
        } else {
            switch tier {
            case "basics": requested = [.postgres]
            case "demo": requested = [.postgres, .security]
            default: requested = []
            }
        }
        let missing = Capability.required(byTier: tier).subtracting(requested)
        if !missing.isEmpty {
            throw CLIError.tierRequiresCapability(
                tier: tier, missing: missing.map(\.rawValue).sorted())
        }
        let rewriter = TraitRewriter(capabilities: requested)

        for (templatePath, templateText) in template.sorted(by: { $0.key < $1.key }) {
            let outPath = project.path(templatePath)
            let outURL = destination.appendingPathComponent(outPath)
            var text = project.contents(templateText, path: templatePath)
            if templatePath == "Package.swift" {
                text = rewriter.rewrite(text)
            }
            do {
                try FileManager.default.createDirectory(
                    at: outURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try text.write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                throw CLIError.writeFailed(outPath, underlying: error)
            }
        }

        let enabled = requested.map(\.rawValue).sorted()
        print(
            "Created \(project.value) at \(destination.path) (\(tier))"
                + (enabled.isEmpty ? "" : " with \(enabled.joined(separator: ", "))"))
        print("")
        print("  cd \(destination.lastPathComponent)")
        if tier != "skeleton" {
            print("  docker run -d -e POSTGRES_PASSWORD=alula -e POSTGRES_DB=app_dev \\")
            print("             -p 55432:5432 postgres:16")
            print("  ALULA_DATABASE_URL=postgres://postgres:alula@127.0.0.1:55432/app_dev \\")
            print("             swift run migrate apply")
        }
        print("  swift run \(project.value)")
    }
}

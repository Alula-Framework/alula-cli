import Testing

@testable import alula

/// `--with`, which chooses a project's dependencies independently of the
/// tier that chooses its code.
@Suite("Capabilities and trait rewriting")
struct TraitsTests {

    @Test("a comma-separated list parses, whitespace and case included")
    func parsing() throws {
        #expect(try Capability.parse("postgres") == [.postgres])
        #expect(try Capability.parse("postgres,valkey") == [.postgres, .valkey])
        #expect(try Capability.parse(" Postgres , VALKEY ") == [.postgres, .valkey])
        #expect(try Capability.parse("") == [])
    }

    @Test("a typo is refused, not ignored")
    func typo() {
        // Silently dropping an unknown name would emit a project quietly
        // missing what was asked for.
        #expect(throws: CLIError.self) { try Capability.parse("postgress") }
        #expect(throws: CLIError.self) { try Capability.parse("postgres,redis") }
    }

    @Test("rewriting sets the trait list on the right package")
    func rewriting() {
        let manifest = """
            dependencies: [
                .package(url: "https://github.com/Alula-Framework/alula.git", from: "0.1.2", traits: ["Web"]),
                .package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.1.2", traits: ["Postgres"]),
            ],
            """

        let both = TraitRewriter(capabilities: [.postgres, .valkey]).rewrite(manifest)
        #expect(both.contains(#"alula-data.git", from: "0.1.2", traits: ["Postgres", "Valkey"])"#))
        // alula is untouched when no alula capability was asked for.
        #expect(both.contains(#"alula.git", from: "0.1.2", traits: ["Web"])"#))

        let secure = TraitRewriter(capabilities: [.postgres, .security]).rewrite(manifest)
        // Security implies Web, so naming both would be redundant.
        #expect(secure.contains(#"alula.git", from: "0.1.2", traits: ["Security"])"#))
    }

    @Test("asking for nothing empties the list rather than dropping the argument")
    func none() {
        let manifest =
            #".package(url: "https://github.com/Alula-Framework/alula-data.git", from: "0.1.2", traits: ["Postgres"]),"#
        let rewritten = TraitRewriter(capabilities: []).rewrite(manifest)
        #expect(rewritten.contains("traits: []"))
    }

    @Test("a tier's code requirements are declared, so they can be enforced")
    func tierRequirements() {
        // basics imports AlulaDataPostgres; demo also uses the security seam.
        #expect(Capability.required(byTier: "basics") == [.postgres])
        #expect(Capability.required(byTier: "demo") == [.postgres, .security])
        #expect(Capability.required(byTier: "skeleton").isEmpty)
    }

    /// Relay #1: `--with valkey,security` on basics turned the traits on and
    /// wired nothing, and nothing said so.
    @Test("capabilities beyond what the tier wires come with the steps left")
    func remainingSteps() {
        let steps = Capability.remainingSteps(
            tier: "basics", requested: [.postgres, .valkey, .security])
        #expect(steps.contains { $0.hasPrefix("valkey:") })
        #expect(steps.contains { $0.hasPrefix("security:") })
        #expect(!steps.contains { $0.hasPrefix("postgres:") }, "basics wires postgres itself")
        #expect(steps.contains { $0.contains("AlulaOIDCModule.self") })
        #expect(Capability.remainingSteps(tier: "demo", requested: [.postgres, .security]).isEmpty)
    }
}

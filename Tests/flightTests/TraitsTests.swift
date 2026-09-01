import Testing

@testable import flight

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
                .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.1.2", traits: ["Web"]),
                .package(url: "https://github.com/Flight-Framework/flight-data.git", from: "0.1.2", traits: ["Postgres"]),
            ],
            """

        let both = TraitRewriter(capabilities: [.postgres, .valkey]).rewrite(manifest)
        #expect(both.contains(#"flight-data.git", from: "0.1.2", traits: ["Postgres", "Valkey"])"#))
        // flight is untouched when no flight capability was asked for.
        #expect(both.contains(#"flight.git", from: "0.1.2", traits: ["Web"])"#))

        let secure = TraitRewriter(capabilities: [.postgres, .security]).rewrite(manifest)
        // Security implies Web, so naming both would be redundant.
        #expect(secure.contains(#"flight.git", from: "0.1.2", traits: ["Security"])"#))
    }

    @Test("asking for nothing empties the list rather than dropping the argument")
    func none() {
        let manifest =
            #".package(url: "https://github.com/Flight-Framework/flight-data.git", from: "0.1.2", traits: ["Postgres"]),"#
        let rewritten = TraitRewriter(capabilities: []).rewrite(manifest)
        #expect(rewritten.contains("traits: []"))
    }

    @Test("a tier's code requirements are declared, so they can be enforced")
    func tierRequirements() {
        // basics imports FlightDataPostgres; demo also uses the security seam.
        #expect(Capability.required(byTier: "basics") == [.postgres])
        #expect(Capability.required(byTier: "demo") == [.postgres, .security])
        #expect(Capability.required(byTier: "skeleton").isEmpty)
    }
}

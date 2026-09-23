import Testing

@testable import alula

/// The rename rules, tested directly.
///
/// `CI/verify-generated-projects.sh` proves a generated project compiles,
/// which is the property that matters — but it takes minutes and only tells
/// you *that* something broke. These say what.
@Suite("Project name validation and rewriting")
struct ProjectNameTests {

    @Test("ordinary names are accepted")
    func valid() throws {
        for name in ["App", "MyService", "api2", "with_underscores", "A"] {
            #expect(throws: Never.self) { try ProjectName(name) }
        }
    }

    @Test("names that could not be a Swift module are refused")
    func invalid() {
        // Each of these would produce a package that does not compile, so the
        // CLI refuses rather than emitting something broken.
        for name in ["", "2fast", "has-a-hyphen", "has space", "has.dot", "class"] {
            #expect(throws: CLIError.self) { try ProjectName(name) }
        }
    }

    @Test("paths move to the new module directory")
    func paths() throws {
        let p = try ProjectName("MyService")
        #expect(p.path("Sources/App/Main.swift") == "Sources/MyService/Main.swift")
        #expect(p.path("Tests/AppTests/X.swift") == "Tests/MyServiceTests/X.swift")
        // Targets that are not the app module are untouched.
        #expect(p.path("Sources/Migrations/1_A.swift") == "Sources/Migrations/1_A.swift")
        #expect(p.path("Sources/migrate/Migrate.swift") == "Sources/migrate/Migrate.swift")
        #expect(p.path("alula.yaml") == "alula.yaml")
    }

    @Test("manifest strings and imports are rewritten")
    func contents() throws {
        let p = try ProjectName("MyService")
        #expect(p.contents(#"name: "App""#, path: "Package.swift") == #"name: "MyService""#)
        #expect(
            p.contents(#"name: "AppTests""#, path: "Package.swift") == #"name: "MyServiceTests""#)
        #expect(
            p.contents("@testable import App", path: "T.swift") == "@testable import MyService")
    }

    @Test("prose is left alone")
    func proseSurvives() throws {
        let p = try ProjectName("MyService")
        // The templates' comments are full of the word "app". A blind
        // find-and-replace would rewrite all of this, which is why the
        // substitutions are anchored to quotes and import statements.
        let prose = """
            /// Your application's module: one place that says what this app is
            /// made of. AppModule is the conventional name for it.
            """
        #expect(p.contents(prose, path: "Main.swift") == prose)
    }

    @Test("alula.yaml's app name is a value, not a quoted identifier")
    func yaml() throws {
        let p = try ProjectName("MyService")
        let yaml = "app:\n  name: App\n\nserver:\n  port: 8080\n"
        #expect(p.contents(yaml, path: "alula.yaml").contains("  name: MyService\n"))
        // The same text in any other file is not a name declaration.
        #expect(p.contents(yaml, path: "README.md").contains("  name: App\n"))
    }

    @Test("every embedded tier is present and non-empty")
    func embedded() {
        #expect(EmbeddedTemplates.tiers == ["basics", "demo", "skeleton"])
        for tier in EmbeddedTemplates.tiers {
            let files = EmbeddedTemplates.files[tier] ?? [:]
            #expect(files["Package.swift"]?.isEmpty == false, "\(tier) has a manifest")
            #expect(files.count > 1, "\(tier) has sources")
        }
    }
}

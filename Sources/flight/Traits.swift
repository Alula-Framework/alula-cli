import Foundation

/// An optional capability a generated project can ask for, and the package
/// trait behind it.
///
/// The tier decides the code; this decides the dependencies. They are
/// separate because a `basics` project wanting Valkey should not have to
/// start from `demo` and delete things.
enum Capability: String, CaseIterable, Sendable {
    case postgres
    case valkey
    case security

    /// `(package identity, trait name)`.
    var trait: (package: String, name: String) {
        switch self {
        case .postgres: ("flight-data", "Postgres")
        case .valkey: ("flight-data", "Valkey")
        case .security: ("flight", "Security")
        }
    }

    var summary: String {
        switch self {
        case .postgres: "PostgreSQL data source, migrations, and the migration CLI"
        case .valkey: "Valkey-backed distributed cache and data source"
        case .security: "OIDC/JWT resource-server authentication"
        }
    }

    /// Parses a comma-separated list, reporting the first unrecognised name
    /// rather than silently ignoring it — a typo in `--with` would otherwise
    /// produce a project quietly missing what was asked for.
    static func parse(_ raw: String) throws -> Set<Capability> {
        var result: Set<Capability> = []
        for piece in raw.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            guard let capability = Capability(rawValue: name) else {
                throw CLIError.unknownCapability(name, available: allCases.map(\.rawValue))
            }
            result.insert(capability)
        }
        return result
    }
}

/// Rewrites a template manifest's `traits:` lists for the requested set.
///
/// The templates carry a working trait list of their own, so this edits what
/// is there rather than composing a manifest from nothing — the file stays
/// the CI-verified one, with two arguments changed.
struct TraitRewriter {
    let capabilities: Set<Capability>

    func rewrite(_ manifest: String) -> String {
        var result = manifest
        for package in ["flight", "flight-data"] {
            let wanted =
                capabilities
                .filter { $0.trait.package == package }
                .map(\.trait.name)
                .sorted()

            // `flight`'s Web trait is not optional in any template: every tier
            // serves HTTP, and Security implies Web anyway.
            var names = wanted
            if package == "flight" && !names.contains("Security") {
                names = ["Web"]
            } else if package == "flight" {
                names = ["Security"]
            }

            result = Self.replacingTraits(in: result, package: package, with: names)
        }
        return result
    }

    /// Replaces the `traits: [...]` argument of one `.package(url:)` line.
    private static func replacingTraits(
        in manifest: String, package: String, with names: [String]
    ) -> String {
        let marker = "Flight-Framework/\(package).git"
        var lines = manifest.split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        guard let index = lines.firstIndex(where: { $0.contains(marker) }) else { return manifest }

        // The declaration may wrap, so find where this one ends.
        var end = index
        while end < lines.count, !lines[end].contains("),") && !lines[end].hasSuffix(")") {
            end += 1
        }

        var declaration = lines[index...end].joined(separator: "\n")
        let rendered =
            names.isEmpty
            ? "traits: []" : "traits: [" + names.map { "\"\($0)\"" }.joined(separator: ", ") + "]"

        if let range = declaration.range(of: #"traits: \[[^\]]*\]"#, options: .regularExpression) {
            declaration.replaceSubrange(range, with: rendered)
        } else if names.isEmpty == false,
            let range = declaration.range(of: #"from: "[0-9.]+""#, options: .regularExpression)
        {
            declaration.replaceSubrange(
                range, with: declaration[range] + ", " + rendered)
        }

        lines.replaceSubrange(
            index...end,
            with: declaration.split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init))
        return lines.joined(separator: "\n")
    }
}

extension Capability {
    /// What a tier's own source requires to compile.
    ///
    /// `--with` chooses dependencies; the tier chooses code. A `basics`
    /// project whose manifest drops Postgres still imports
    /// `FlightDataPostgres`, so the combination has to be refused rather
    /// than emitted — a generated project that does not build is the worst
    /// thing this command can produce.
    static func required(byTier tier: String) -> Set<Capability> {
        switch tier {
        case "basics": [.postgres]
        case "demo": [.postgres, .security]
        default: []
        }
    }
}

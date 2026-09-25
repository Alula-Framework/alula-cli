import Foundation

enum CLIError: Error, CustomStringConvertible {
    case invalidName(String, String)
    case unknownTier(String, available: [String])
    case destinationExists(String)
    case writeFailed(String, underlying: any Error)
    case notAPackage(String)
    case noMigrateExecutable(String)
    case delegateFailed(Int32)
    case manifestUnrecognised(String)
    case unknownCapability(String, available: [String])
    case tierRequiresCapability(tier: String, missing: [String])
    case noRouteManifest(String)
    case ambiguousProduct([String])
    case fileExists(String)
    case missingProducts([String])
    case ambiguousTarget([String])
    case unknownDiagnosticCode(String, suggestions: [String])

    var description: String {
        switch self {
        case .invalidName(let name, let why):
            return "'\(name)' is not a usable project name: \(why)."
        case .unknownTier(let tier, let available):
            return "no template named '\(tier)'. Available: \(available.joined(separator: ", "))."
        case .destinationExists(let path):
            return "\(path) already exists. Choose another name, or pass --force to write into it."
        case .writeFailed(let path, let underlying):
            return "could not write \(path): \(underlying)"
        case .unknownDiagnosticCode(let code, let suggestions):
            return suggestions.isEmpty
                ? "Alula has no diagnostic code '\(code)'. `alula explain` lists every code."
                : "Alula has no diagnostic code '\(code)'. Did you mean \(suggestions.joined(separator: ", "))?"
        case .ambiguousTarget(let targets):
            return targets.isEmpty
                ? "no application target under Sources/. Name one with --target."
                : "Sources/ holds several targets (\(targets.joined(separator: ", "))). Name one with --target."
        case .missingProducts(let products):
            return """
                the generated code needs \(products.joined(separator: ", ")), which this \
                package's Package.swift does not name. Add them as dependencies of the app \
                (the *Testing ones of its test target), with the Security trait on alula and \
                the Postgres trait on alula-data — the demo template's Package.swift has all of them.
                """
        case .fileExists(let path):
            return "\(path) already exists; nothing was written. Choose another name."
        case .ambiguousProduct(let products):
            return products.isEmpty
                ? "this package has no executable product to run."
                : "this package has several executables (\(products.joined(separator: ", "))). Pick one with --product."
        case .noRouteManifest(let path):
            return """
                no route manifest under \(path)/.build/plugins/outputs. Build the project first \
                (drop --no-build), and check its target uses AlulaRegistrationPlugin.
                """
        case .notAPackage(let path):
            return """
                no Package.swift found in \(path) or any parent directory. \
                Run this from inside an Alula project.
                """
        case .noMigrateExecutable(let path):
            return """
                \(path) has no 'migrate' executable target, so there is nothing \
                to run migrations with. Add one with:

                    alula migrate init
                """
        case .delegateFailed(let code):
            return "migrate exited with status \(code)"
        case .unknownCapability(let name, let available):
            return """
                '\(name)' is not something --with knows about. \
                Available: \(available.joined(separator: ", ")).
                """
        case .tierRequiresCapability(let tier, let missing):
            return """
                the '\(tier)' template's own code needs \(missing.joined(separator: " and ")), \
                so --with must include \(missing.joined(separator: ",")). \
                Start from 'skeleton' for a project without them.
                """
        case .manifestUnrecognised(let why):
            return """
                could not add the migration targets automatically: \(why). \
                Add them by hand — see the basics template's Package.swift.
                """
        }
    }
}

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

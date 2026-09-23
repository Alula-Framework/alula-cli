import Foundation

/// A validated project name, and the rules for turning a template into a
/// project that carries it.
///
/// The templates are written with the target named `App`, because they have to
/// compile and be tested as they stand. Generating a project therefore means
/// renaming `App` — and doing that with a blind find-and-replace would corrupt
/// prose, since the templates' comments are full of the word "app". The
/// substitutions below are deliberately narrow: quoted manifest strings,
/// import statements, and path components. Anything else keeps saying "app".
struct ProjectName {
    let value: String

    /// Swift target names must be valid identifiers, and SwiftPM uses the
    /// name for the module — so this is stricter than a directory name needs
    /// to be, on purpose.
    init(_ raw: String) throws {
        guard !raw.isEmpty else { throw CLIError.invalidName(raw, "it is empty") }
        guard raw.first!.isLetter else {
            throw CLIError.invalidName(raw, "it must start with a letter")
        }
        guard raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw CLIError.invalidName(
                raw, "it may contain only letters, numbers, and underscores")
        }
        guard !Self.reserved.contains(raw) else {
            throw CLIError.invalidName(raw, "'\(raw)' is a reserved Swift keyword")
        }
        // "App" is what the templates already use; renaming it to itself is a
        // no-op, not an error.
        self.value = raw
    }

    private static let reserved: Set<String> = [
        "Any", "Protocol", "Self", "Type", "as", "associatedtype", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
        "init", "inout", "internal", "is", "let", "nil", "operator", "private", "protocol",
        "public", "repeat", "rethrows", "return", "self", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where",
        "while",
    ]

    /// Rewrites one template file's path for this project.
    func path(_ templatePath: String) -> String {
        templatePath
            .replacingOccurrences(of: "Sources/App/", with: "Sources/\(value)/")
            .replacingOccurrences(of: "Tests/AppTests/", with: "Tests/\(value)Tests/")
    }

    /// Rewrites one template file's contents for this project.
    ///
    /// Ordering matters: `AppTests` must be rewritten before the bare `App`
    /// forms, or `"AppTests"` would become `"<name>Tests"` only by accident of
    /// the longer pattern winning.
    func contents(_ text: String, path: String) -> String {
        var out = text
        for (needle, replacement) in [
            (#""AppTests""#, #""\#(value)Tests""#),
            (#"@testable import App"#, "@testable import \(value)"),
            (#""App""#, #""\#(value)""#),
        ] {
            out = out.replacingOccurrences(of: needle, with: replacement)
        }
        // alula.yaml's `app.name`, which is a value rather than an identifier
        // and so is not quoted in the file.
        if path == "alula.yaml" {
            out = out.replacingOccurrences(of: "  name: App\n", with: "  name: \(value)\n")
        }
        return out
    }
}

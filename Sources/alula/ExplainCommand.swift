import AlulaDiagnostics
import ArgumentParser
import Foundation

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain an Alula diagnostic code.",
        discussion: """
            Every error and warning Alula reports at build time carries a code, \
            such as [ALU-DI-1001]. This prints that code's page — what it means, \
            why Alula rejects it, and how to fix it — the same text as the \
            page the diagnostic links to, available offline.

              alula explain ALU-DI-1001    one code's page
              alula explain 1001           the number alone is enough
              alula explain                every code, by family
            """
    )

    @Argument(help: "The code, e.g. ALU-DI-1001 or 1001. Omit to list every code.")
    var code: String?

    func run() throws {
        guard let code else {
            print(Self.list())
            return
        }
        print(try Self.page(for: code))
    }

    /// The page for `query`, formatted for a terminal.
    static func page(for query: String) throws -> String {
        guard let code = lookup(query) else {
            if let hangar = hangarPage(for: query) { return hangar }
            throw CLIError.unknownDiagnosticCode(query, suggestions: suggestions(for: query))
        }
        guard let page = code.page else {
            // A code without a page is a bug in Alula, which tests there
            // prevent; say what is known rather than nothing.
            return "\(code.id): \(code.title)\n\n\(code.documentationURL)"
        }
        return terminal(page) + "\nOnline: \(code.documentationURL)"
    }

    /// Hangar's query codes live with Hangar, which does not depend on Alula,
    /// so their pages are Hangar's to publish; point at them.
    static func hangarPage(for query: String) -> String? {
        let id = query.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard id.wholeMatch(of: /HGR-QUERY-\d{4}/) != nil else { return nil }
        return "\(id) is a Hangar query diagnostic. Its page:\n"
            + "https://github.com/Alula-Framework/hangar/blob/main/Diagnostics/\(id).md"
    }

    /// Exact id, case-insensitive; or the number alone, when one code has it.
    static func lookup(_ query: String) -> DiagnosticCode? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let exact = DiagnosticCode.named(trimmed) { return exact }
        let byNumber = DiagnosticCode.all.filter { $0.id.hasSuffix("-" + trimmed) }
        return byNumber.count == 1 ? byNumber[0] : nil
    }

    /// The three codes numerically closest to the query, within its family
    /// when it names one — for a typo or a transposed digit.
    static func suggestions(for query: String) -> [String] {
        let parts = query.uppercased().split(separator: "-")
        guard let wanted = parts.last.flatMap({ Int($0) }) else { return [] }
        let family = parts.dropLast().joined(separator: "-")
        let candidates = DiagnosticCode.all.filter { family.isEmpty || $0.id.hasPrefix(family + "-") }
        return candidates
            .sorted { abs(number($0) - wanted) < abs(number($1) - wanted) }
            .prefix(3).map(\.id).sorted()
    }

    /// Every code, grouped by family in numeric order.
    static func list() -> String {
        var lines: [String] = []
        var family = ""
        for code in DiagnosticCode.all.sorted(by: { number($0) < number($1) }) {
            let thisFamily = code.id.split(separator: "-").dropLast().joined(separator: "-")
            if thisFamily != family {
                if !family.isEmpty { lines.append("") }
                family = thisFamily
            }
            let severity = code.severity == .warning ? "warning" : "error  "
            lines.append("\(code.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(severity)  \(code.title)")
        }
        lines.append("")
        lines.append("alula explain <code> prints one.")
        return lines.joined(separator: "\n")
    }

    private static func number(_ code: DiagnosticCode) -> Int {
        Int(code.id.split(separator: "-").last ?? "") ?? 0
    }

    /// Markdown made readable as plain text: headings lose their markers,
    /// bold loses its asterisks. Code blocks and lists read fine as they are.
    static func terminal(_ markdown: String) -> String {
        var output: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            if text.hasPrefix("# ") {
                text = String(text.dropFirst(2))
                output.append(text)
                output.append(String(repeating: "=", count: text.count))
                continue
            }
            if text.hasPrefix("## ") {
                text = String(text.dropFirst(3))
                output.append(text)
                output.append(String(repeating: "-", count: text.count))
                continue
            }
            if text.hasPrefix("```") { continue }
            output.append(text.replacingOccurrences(of: "**", with: ""))
        }
        return output.joined(separator: "\n")
    }
}

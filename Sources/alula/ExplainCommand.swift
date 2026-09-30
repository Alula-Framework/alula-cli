import AlulaDiagnostics
import ArgumentParser
import Foundation

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain an Alula diagnostic code.",
        discussion: """
            Every error and warning Alula reports at build time, and every \
            startup failure, carries a code such as [ALU-DI-1001]. This prints \
            that code's page — what it means, why Alula rejects it, and how to \
            fix it — the same text as the page the diagnostic links to, \
            available offline.

              alula explain ALU-DI-1001    one code's page
              alula explain 1001           the number alone, for an ALU code
              alula explain                every code, by family

            Hangar (HGR-QUERY-…) and alula-data (ALD-…) codes are published \
            by those packages; give the full code and this prints the link \
            to its page. Their numbers are not unique on their own \
            (ALD-CACHE-1001 and ALD-DATA-1001 both exist), so a bare number \
            only ever looks up an ALU code.
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
            if let external = externalPage(for: query) { return external }
            throw CLIError.unknownDiagnosticCode(query, suggestions: suggestions(for: query))
        }
        guard let page = code.page else {
            // A code without a page is a bug in Alula, which tests there
            // prevent; say what is known rather than nothing.
            return "\(code.id): \(code.title)\n\n\(code.documentationURL)"
        }
        return terminal(page) + "\nOnline: \(code.documentationURL)"
    }

    /// Hangar's and alula-data's codes live with those packages — Hangar does
    /// not depend on Alula, and alula-data releases on its own — so their
    /// pages are theirs to publish; point at them.
    static func externalPage(for query: String) -> String? {
        let id = query.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let owners: [(pattern: Regex<Substring>, name: String, repository: String)] = [
            (/HGR-QUERY-\d{4}/, "a Hangar query diagnostic", "hangar"),
            (/ALD-[A-Z]+-\d{4}/, "an alula-data diagnostic", "alula-data"),
        ]
        guard let owner = owners.first(where: { id.wholeMatch(of: $0.pattern) != nil }) else {
            return nil
        }
        return "\(id) is \(owner.name). Its page:\n"
            + "https://github.com/Alula-Framework/\(owner.repository)/blob/main/Diagnostics/\(id).md"
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
        let candidates = DiagnosticCode.all.filter {
            family.isEmpty || $0.id.hasPrefix(family + "-")
        }
        return
            candidates
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
            lines.append(
                "\(code.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(severity)  \(code.title)"
            )
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
            // A fence can be indented, as one inside a list item is
            // (ALU-CONFIG-5014's fixes); the code under it keeps its indent.
            if text.drop(while: { $0 == " " }).hasPrefix("```") { continue }
            output.append(text.replacingOccurrences(of: "**", with: ""))
        }
        return output.joined(separator: "\n")
    }
}

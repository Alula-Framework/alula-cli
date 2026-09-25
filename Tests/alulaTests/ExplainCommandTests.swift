import AlulaDiagnostics
import Foundation
import Testing

@testable import alula

@Suite("alula explain")
struct ExplainCommandTests {
    /// A code as a reader copies it from build output — bracketed, in any
    /// case, or as the number alone — finds its page.
    @Test(
        "a code is found however it is copied",
        arguments: [
            "ALU-DI-1001", "alu-di-1001", "[ALU-DI-1001]", " ALU-DI-1001 ", "1001",
        ])
    func lookup(_ query: String) {
        #expect(Explain.lookup(query) == .missingProvider)
    }

    @Test("every code Alula defines has a readable page")
    func everyCodeHasAPage() throws {
        for code in DiagnosticCode.all {
            let page = try Explain.page(for: code.id)
            #expect(page.hasPrefix("\(code.id): \(code.title)"), "\(code.id)")
            #expect(page.contains("Fixes\n-----"), "\(code.id) has no fixes section")
            #expect(
                !page.contains("**") && !page.contains("```"), "\(code.id) kept markdown syntax")
            #expect(page.hasSuffix("Online: \(code.documentationURL)"))
        }
    }

    /// ALU-DI-1004 is deliberately unassigned; asking for it should land
    /// the reader on its neighbours rather than on a dead end.
    @Test("an unknown code suggests its nearest neighbours")
    func unknownCode() {
        #expect(throws: CLIError.self) { try Explain.page(for: "ALU-DI-1004") }
        #expect(
            Explain.suggestions(for: "ALU-DI-1004") == [
                "ALU-DI-1002", "ALU-DI-1003", "ALU-DI-1005",
            ])
        #expect(Explain.suggestions(for: "not-a-code").isEmpty)
    }

    @Test("a Hangar code points at Hangar's page")
    func hangarCode() throws {
        let page = try Explain.page(for: "[hgr-query-4001]")
        #expect(page.hasSuffix("/hangar/blob/main/Diagnostics/HGR-QUERY-4001.md"))
    }

    @Test("the listing names every code once")
    func listing() {
        let listing = Explain.list()
        for code in DiagnosticCode.all {
            #expect(listing.components(separatedBy: code.id + " ").count == 2, "\(code.id)")
        }
    }
}

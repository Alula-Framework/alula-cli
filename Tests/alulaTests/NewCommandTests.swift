import Foundation
import Testing

@testable import alula

@Suite("Next-steps output")
struct NextStepsTests {
    /// The commands `alula new` prints must be commands that exist.
    ///
    /// It printed `swift run migrate up` for weeks. `up` is not a
    /// subcommand — it is `apply` — so the very first thing a new project was
    /// told to do failed. The tutorial was corrected for this and the CLI's
    /// own output was not, which is the argument for checking it here rather
    /// than in prose.
    @Test("the migrate command it suggests is a real subcommand")
    func suggestsRealMigrateSubcommand() throws {
        let source = try String(
            contentsOf: Self.packageRoot().appendingPathComponent(
                "Sources/alula/NewCommand.swift"), encoding: .utf8)
        let suggested =
            source
            .split(separator: "\n")
            .filter { $0.contains("swift run migrate") }
            .map { line -> String in
                guard let range = line.range(of: "swift run migrate ") else { return "" }
                return String(line[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\") "))
            }
            .filter { !$0.isEmpty }

        #expect(!suggested.isEmpty, "no migrate suggestion found — did the output change?")
        // Mirrors AlulaMigrateCLI's subcommand list.
        let real: Set<String> = ["apply", "status", "rollback", "create", "repair"]
        for command in suggested {
            #expect(real.contains(command), "`swift run migrate \(command)` is not a subcommand")
        }
    }

    /// A bare `swift run <Name>` declares no environment, and since alula
    /// 0.60.0 the demo tier refuses to start that way (ALU-CONFIG-5013): it
    /// has no mail transport, and logging mail needs development declared.
    @Test("the run step declares the development environment")
    func runStepDeclaresDevelopment() throws {
        let source = try String(
            contentsOf: Self.packageRoot().appendingPathComponent(
                "Sources/alula/NewCommand.swift"), encoding: .utf8)
        let runLines = source.split(separator: "\n").filter {
            $0.contains("print(") && $0.contains("swift run \\(project.value)")
        }
        #expect(runLines.count == 1, "no run step found — did the output change?")
        for line in runLines {
            #expect(line.contains("alula dev"))
            #expect(line.contains("ALULA_ENV=dev swift run"))
        }
    }

    private static func packageRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path)
        {
            let parent = root.deletingLastPathComponent()
            precondition(parent.path != root.path, "no Package.swift above \(#filePath)")
            root = parent
        }
        return root
    }
}

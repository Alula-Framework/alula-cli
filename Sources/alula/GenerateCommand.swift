import ArgumentParser
import Foundation

struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Write new source files in this project's conventions.",
        subcommands: [GenerateController.self]
    )
}

struct GenerateController: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "controller",
        abstract: "A @Controller with list and show routes, and a test for it.",
        discussion: """
              alula generate controller Orders
                Sources/App/Controllers/OrdersController.swift   @Controller("/orders")
                Tests/AppTests/OrdersControllerTests.swift        through TestClient

            The name may be given as Orders, orders, OrderItems or order-items. \
            Nothing is overwritten.
            """
    )

    @Argument(help: "The controller's name, without the Controller suffix.")
    var name: String

    @Option(help: "The executable target the controller belongs to.")
    var target = "App"

    func run() throws {
        let project = try Project.locate()
        let names = try ControllerNames(name)
        let source = project.root.appendingPathComponent(
            "Sources/\(target)/Controllers/\(names.type).swift")
        let test = project.root.appendingPathComponent(
            "Tests/\(target)Tests/\(names.type)Tests.swift")
        for file in [source, test] where FileManager.default.fileExists(atPath: file.path) {
            throw CLIError.fileExists(file.path)
        }
        try write(names.controllerSource(), to: source)
        try write(names.testSource(target: target), to: test)
        print("created \(source.path.replacingOccurrences(of: project.root.path + "/", with: ""))")
        print("created \(test.path.replacingOccurrences(of: project.root.path + "/", with: ""))")
        print("routes: GET \(names.path), GET \(names.path)/:id")
    }

    private func write(_ contents: String, to file: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError.writeFailed(file.path, underlying: error)
        }
    }
}

/// `order-items` → `OrderItemsController` at `/order-items`.
struct ControllerNames: Equatable {
    let type: String
    let path: String

    init(_ raw: String) throws {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("Controller") { name = String(name.dropLast("Controller".count)) }
        let words = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .flatMap { ControllerNames.camelWords(String($0)) }
        guard !words.isEmpty,
            words.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber } }),
            words[0].first?.isLetter == true
        else {
            throw CLIError.invalidName(raw, "use letters and digits, starting with a letter")
        }
        type = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Controller"
        path = "/" + words.map { $0.lowercased() }.joined(separator: "-")
    }

    /// `OrderItems` → `["Order", "Items"]`; `orders` → `["orders"]`.
    static func camelWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isUppercase, !current.isEmpty, current.last?.isLowercase == true {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    func controllerSource() -> String {
        """
        import AlulaCore
        import AlulaWeb
        import Foundation

        /// \(path): replace the placeholder bodies with the real thing.
        @Controller("\(path)")
        struct \(type) {

            @GetRoute("/")
            func list(_ context: RequestContext) async throws -> [String] {
                []
            }

            /// A segment that is not a UUID is a 400 before this runs.
            @GetRoute("/:id")
            func show(_ context: RequestContext, id: UUID) async throws -> String {
                throw HTTPError(.notFound, "no \\(id)")
            }
        }

        """
    }

    func testSource(target: String) -> String {
        """
        import AlulaCore
        import AlulaWeb
        import AlulaWebTesting
        import Foundation
        import Testing

        @testable import \(target)

        @Suite("\(type)")
        struct \(type)Tests {
            private func client() throws -> TestClient {
                try TestClient(routes: \(type).alulaRoutes { _ in \(type)() })
            }

            @Test("list answers")
            func list() async throws {
                #expect(await (try client()).get("\(path)").status == .ok)
            }

            @Test("show refuses an id that is not a UUID")
            func showValidatesTheID() async throws {
                #expect(await (try client()).get("\(path)/not-a-uuid").status == .badRequest)
            }
        }

        """
    }
}

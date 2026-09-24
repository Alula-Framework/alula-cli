import ArgumentParser
import Foundation

struct Routes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "routes",
        abstract: "List every route this project declares.",
        discussion: """
            Builds the project, then reads the route manifest Alula's build \
            plugin writes from the @Controller routes it scanned: method, \
            path, the lanes each route runs through, and the handler. \
            Framework routes (Actuator, uploads, /openapi.json) are \
            registered by modules at run time and are not listed.

              alula routes               a table
              alula routes --json        one object per route
              alula routes --no-build    read the last build's manifest
            """
    )

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    @Flag(help: "Skip `swift build`; read the manifest the last build wrote.")
    var noBuild = false

    func run() async throws {
        let project = try Project.locate()
        if !noBuild {
            let status = try Migrate.runSwift(["build"], in: project.root)
            guard status == 0 else { throw CLIError.delegateFailed(status) }
        }
        let routes = try RouteManifest.read(in: project.root)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(routes), as: UTF8.self))
        } else {
            print(RouteManifest.table(routes))
        }
    }
}

/// The routes Alula's build plugin recorded in `AlulaRegistration.generated.swift`.
enum RouteManifest {
    struct Route: Codable, Equatable {
        let method: String
        let path: String
        let handler: String
        let lanes: String?
        let webSocket: Bool
    }

    static func read(in root: URL) throws -> [Route] {
        let outputs = root.appendingPathComponent(".build/plugins/outputs")
        guard
            let files = FileManager.default.enumerator(at: outputs, includingPropertiesForKeys: nil)
        else { throw CLIError.noRouteManifest(root.path) }
        var routes: [Route] = []
        var found = false
        for case let file as URL in files
        where file.lastPathComponent == "AlulaRegistration.generated.swift" {
            found = true
            routes += parse(try String(contentsOf: file, encoding: .utf8))
        }
        guard found else { throw CLIError.noRouteManifest(root.path) }
        // One target's manifest can appear under more than one build
        // configuration; a route is itself only once.
        var seen = Set<String>()
        return routes.filter { seen.insert("\($0.method) \($0.path) \($0.handler)").inserted }
            .sorted { ($0.path, $0.method) < ($1.path, $1.method) }
    }

    /// One `Entry(method: "GET", path: "/x", source: "M.C.f", pipelines: nil, isUpgrade: false),`
    /// per line — the shape the generator writes.
    static func parse(_ generated: String) -> [Route] {
        let pattern =
            #"Entry\(method: "([^"]*)", path: "((?:[^"\\]|\\.)*)", source: "((?:[^"\\]|\\.)*)", pipelines: (nil|"((?:[^"\\]|\\.)*)"), isUpgrade: (true|false)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(generated.startIndex..., in: generated)
        return regex.matches(in: generated, range: range).compactMap { match in
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: generated).map { unescape(String(generated[$0])) }
            }
            guard let method = group(1), let path = group(2), let source = group(3),
                let upgrade = group(6)
            else { return nil }
            return Route(
                method: method, path: path, handler: source, lanes: group(5),
                webSocket: upgrade == "true")
        }
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(
            of: #"\\"#, with: "\\")
    }

    static func table(_ routes: [Route]) -> String {
        guard !routes.isEmpty else { return "No routes. Is there a @Controller in this project?" }
        let rows =
            [["METHOD", "PATH", "LANES", "HANDLER"]]
            + routes.map {
                [$0.webSocket ? "WS" : $0.method, $0.path, $0.lanes ?? "default", $0.handler]
            }
        let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == 3
                    ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

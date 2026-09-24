import Foundation
import Testing

@testable import alula

@Suite("alula routes")
struct RouteManifestTests {
    /// The generator's own output shape, escapes included.
    let generated = #"""
        public static let routes: [Entry] = [
            Entry(method: "GET", path: "/users/:id", source: "App.UserController.show", pipelines: nil, isUpgrade: false),
            Entry(method: "POST", path: "/session", source: "App.SessionController.signIn", pipelines: "[.default, \"csrf\"]", isUpgrade: false),
            Entry(method: "GET", path: "/socket", source: "App.SocketController.socket", pipelines: nil, isUpgrade: true),
        ]
        """#

    @Test("reads every entry the generator writes, escaped quotes included")
    func parses() {
        let routes = RouteManifest.parse(generated)
        #expect(routes.count == 3)
        #expect(
            routes[1]
                == .init(
                    method: "POST", path: "/session", handler: "App.SessionController.signIn",
                    lanes: #"[.default, "csrf"]"#, webSocket: false))
        #expect(routes[2].webSocket)
        #expect(routes[0].lanes == nil)
    }

    @Test("the table labels WebSockets and the default lane")
    func table() {
        let table = RouteManifest.table(RouteManifest.parse(generated))
        #expect(table.contains("WS      /socket"))
        #expect(table.contains("default"))
        #expect(table.hasPrefix("METHOD"))
    }
}

@Suite("alula generate controller")
struct ControllerNamesTests {
    @Test("names become a type and a path, however they are written")
    func names() throws {
        for (input, type, path) in [
            ("Orders", "OrdersController", "/orders"),
            ("orders", "OrdersController", "/orders"),
            ("OrderItems", "OrderItemsController", "/order-items"),
            ("order-items", "OrderItemsController", "/order-items"),
            ("order_items", "OrderItemsController", "/order-items"),
            ("OrderItemsController", "OrderItemsController", "/order-items"),
        ] {
            let names = try ControllerNames(input)
            #expect(names.type == type, "\(input)")
            #expect(names.path == path, "\(input)")
        }
    }

    @Test("names that are not identifiers are refused")
    func refused() {
        for bad in ["", "1orders", "order$", "Controller"] {
            #expect(throws: CLIError.self, "\(bad)") { try ControllerNames(bad) }
        }
    }

    @Test("the generated controller uses routes the macro accepts")
    func source() throws {
        let source = try ControllerNames("orders").controllerSource()
        #expect(source.contains(#"@Controller("/orders")"#))
        #expect(source.contains(#"@GetRoute("/")"#))
        #expect(!source.contains(#"@GetRoute("")"#))
    }
}

@Suite("alula dev watcher")
struct WatcherTests {
    @Test("a new, changed or removed source changes the signature")
    func signature() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "alula-dev-\(UUID())")
        let sources = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(
            to: sources.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "x: 1".write(
            to: root.appendingPathComponent("alula.yaml"), atomically: true, encoding: .utf8)
        let first = Watcher.signature(of: root)
        #expect(first.keys.contains { $0.hasSuffix("alula.yaml") })

        try "b".write(
            to: sources.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let added = Watcher.signature(of: root)
        #expect(added != first)

        try FileManager.default.removeItem(at: sources.appendingPathComponent("B.swift"))
        let removed = Watcher.signature(of: root)
        #expect(removed != added, "a deletion is a change too")
        #expect(!removed.keys.contains { $0.hasSuffix("B.swift") })
    }
}

@Suite("generators find the app target")
struct AppTargetTests {
    private func project(_ directories: [String]) throws -> Project {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "alula-target-\(UUID())")
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Sources/\(directory)"),
                withIntermediateDirectories: true)
        }
        return Project(root: root)
    }

    @Test("the one target beside the migrations is the app, whatever it is called")
    func found() throws {
        #expect(try project(["Shop", "Migrations", "migrate"]).appTarget(nil) == "Shop")
    }

    @Test("--target wins, and several candidates without it are refused")
    func ambiguous() throws {
        let several = try project(["Shop", "Admin", "Migrations"])
        #expect(try several.appTarget("Admin") == "Admin")
        #expect(throws: CLIError.self) { try several.appTarget(nil) }
    }
}

@Suite("alula generate auth")
struct GenerateAuthTests {
    @Test("the auth files are embedded, and not offered as a project template")
    func embedded() throws {
        let files = try #require(EmbeddedTemplates.files["_auth"])
        #expect(files.keys.contains("Sources/App/Accounts/AccountFlows.swift"))
        #expect(files.keys.contains { $0.hasPrefix("Sources/Migrations/__TIMESTAMP___") })
        #expect(!EmbeddedTemplates.tiers.contains("_auth"))
    }

    @Test("timestamps are the fourteen UTC digits migrations are named with")
    func timestamp() {
        #expect(GenerateAuth.timestamp(Date(timeIntervalSince1970: 0)) == "19700101000000")
    }
}

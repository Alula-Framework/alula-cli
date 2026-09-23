import Foundation
import Testing

@testable import alula

@Suite("Locating the project")
struct ProjectTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alula-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a package is found from a nested directory")
    func findsFromNested() throws {
        let root = try scratch()
        try "// swift-tools-version: 6.3".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("Sources/App/Controllers")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // Running `alula migrate` from anywhere inside a project should work,
        // the way git does.
        // Compared by path, not by URL: Foundation gives a directory URL a
        // trailing slash when the directory exists, so file:///a/b/ and
        // file:///a/b are unequal URLs for the same directory.
        let found = try Project.locate(from: nested).root
        #expect(found.path == root.standardizedFileURL.path)
    }

    @Test("no package anywhere above is an error, not a silent guess")
    func failsOutsideAPackage() throws {
        let empty = try scratch()
        #expect(throws: CLIError.self) { try Project.locate(from: empty) }
    }

    @Test("a migrate target is detected from the manifest")
    func detectsMigrateTarget() throws {
        let root = try scratch()
        let manifest = root.appendingPathComponent("Package.swift")

        try #"let package = Package(name: "App", targets: [.target(name: "App")])"#
            .write(to: manifest, atomically: true, encoding: .utf8)
        #expect(Project(root: root).hasMigrateExecutable == false)

        try #"let package = Package(targets: [.executableTarget(name: "migrate")])"#
            .write(to: manifest, atomically: true, encoding: .utf8)
        #expect(Project(root: root).hasMigrateExecutable == true)
    }
}

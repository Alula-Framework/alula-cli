import Foundation

/// The Swift package the CLI is being run against.
struct Project {
    let root: URL

    /// Walks up from `start` looking for a `Package.swift`, so the CLI works
    /// from anywhere inside a project rather than only at its root — the way
    /// git finds its repository.
    ///
    /// Walks path strings rather than URLs: `URL.deletingLastPathComponent()`
    /// leaves a trailing slash, so `file:///a/b/` never compares equal to the
    /// `file:///a/b` a caller constructs, and the loop's own termination check
    /// is an equality test.
    static func locate(
        from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> Project {
        var path = start.standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: path + "/Package.swift") {
                return Project(root: URL(fileURLWithPath: path))
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { break }
            path = parent
        }
        throw CLIError.notAPackage(start.path)
    }

    var manifest: String {
        (try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8))
            ?? ""
    }

    /// Whether this package builds the migrate executable. Checked before
    /// delegating, so a project without it gets an explanation and a fix
    /// rather than SwiftPM's "no executable product named 'migrate'".
    var hasMigrateExecutable: Bool {
        manifest.contains(#"name: "migrate""#)
    }

    /// The application target generated code goes into: `explicit` when
    /// given, otherwise the one directory under Sources/ that is not the
    /// migrations. `alula new` names it after the project, so `App` cannot
    /// be assumed.
    func appTarget(_ explicit: String?) throws -> String {
        if let explicit { return explicit }
        let sources = root.appendingPathComponent("Sources")
        let candidates =
            ((try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? [])
            .filter { name in
                var isDirectory: ObjCBool = false
                return !name.hasPrefix(".") && name != "Migrations" && name != "migrate"
                    && FileManager.default.fileExists(
                        atPath: sources.appendingPathComponent(name).path, isDirectory: &isDirectory
                    )
                    && isDirectory.boolValue
            }
            .sorted()
        guard candidates.count == 1 else { throw CLIError.ambiguousTarget(candidates) }
        return candidates[0]
    }

    var migrationsDirectory: URL {
        root.appendingPathComponent("Sources/Migrations")
    }
}

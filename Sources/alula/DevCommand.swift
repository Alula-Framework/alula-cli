import ArgumentParser
import Foundation

struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build and run the app, rebuilding and restarting it when a source file changes.",
        discussion: """
            Watches Sources/, Package.swift and alula*.yaml. On a change it \
            rebuilds. When the build succeeds, the running app is stopped \
            with SIGTERM, as in production, so it drains and shuts down in \
            order, and the new build starts. When the build fails, the old \
            app keeps running and the errors are shown.

              alula dev                   the package's executable (not `migrate`)
              alula dev --product Worker  a specific one
              alula dev -- --flag         arguments for the app
            """
    )

    @Option(
        help: "The executable product to run. Default: the package's only one besides `migrate`.")
    var product: String?

    @Option(help: "How often to look for changes, in milliseconds.")
    var pollMs: Int = 500

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the app.")
    var arguments: [String] = []

    func run() async throws {
        let project = try Project.locate()
        let product = try self.product ?? Self.defaultProduct(in: project.root)
        let binDirectory = try Self.binPath(in: project.root)
        let runner = AppRunner(
            executable: binDirectory.appendingPathComponent(product), arguments: arguments)

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            print("\nalula dev: stopping")
            runner.stop()
            Foundation.exit(0)
        }
        interrupt.resume()

        var signature = Watcher.signature(of: project.root)
        if Self.build(product, in: project.root) { runner.start() }
        while true {
            try await Task.sleep(for: .milliseconds(max(pollMs, 100)))
            let now = Watcher.signature(of: project.root)
            guard now != signature else { continue }
            // Let an editor finish writing a batch of files.
            try await Task.sleep(for: .milliseconds(300))
            signature = Watcher.signature(of: project.root)
            print("alula dev: change detected, rebuilding")
            if Self.build(product, in: project.root) {
                runner.stop()
                runner.start()
            } else {
                print("alula dev: build failed; still running the previous build")
            }
        }
    }

    static func build(_ product: String, in root: URL) -> Bool {
        (try? Migrate.runSwift(["build", "--product", product], in: root)) == 0
    }

    static func binPath(in root: URL) throws -> URL {
        let output = try capture(["swift", "build", "--show-bin-path"], in: root)
        return URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The package's executable product, when there is exactly one besides `migrate`.
    static func defaultProduct(in root: URL) throws -> String {
        let description = try capture(["swift", "package", "describe", "--type", "json"], in: root)
        let json = try JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any]
        let products = (json?["products"] as? [[String: Any]]) ?? []
        let executables = products.compactMap { product -> String? in
            guard let type = product["type"] as? [String: Any], type["executable"] != nil else {
                return nil
            }
            return product["name"] as? String
        }.filter { $0 != "migrate" }
        guard executables.count == 1, let only = executables.first else {
            throw CLIError.ambiguousProduct(executables)
        }
        return only
    }

    static func capture(_ command: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError.delegateFailed(process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What changed means: any watched file's modification time, or the set of
/// files itself.
enum Watcher {
    static func signature(of root: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        let manager = FileManager.default
        var roots = [root.appendingPathComponent("Sources")]
        if let entries = try? manager.contentsOfDirectory(atPath: root.path) {
            for name in entries
            where name == "Package.swift" || (name.hasPrefix("alula") && name.hasSuffix(".yaml")) {
                roots.append(root.appendingPathComponent(name))
            }
        }
        for watched in roots {
            if let enumerator = manager.enumerator(
                at: watched, includingPropertiesForKeys: [.contentModificationDateKey])
            {
                for case let file as URL in enumerator {
                    result[file.path] =
                        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                }
            }
            if let attributes = try? manager.attributesOfItem(atPath: watched.path),
                attributes[.type] as? FileAttributeType == .typeRegular
            {
                result[watched.path] = attributes[.modificationDate] as? Date
            }
        }
        return result
    }
}

/// The app process: started with the CLI's stdio, stopped as an orchestrator
/// would stop it.
final class AppRunner: @unchecked Sendable {
    let executable: URL
    let arguments: [String]
    private let lock = NSLock()
    private var process: Process?

    init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func start() {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try process.run()
            lock.withLock { self.process = process }
            print(
                "alula dev: running \(executable.lastPathComponent) (pid \(process.processIdentifier))"
            )
        } catch {
            print("alula dev: could not start \(executable.path): \(error)")
        }
    }

    /// SIGTERM, then up to ten seconds for a graceful shutdown, then SIGKILL.
    func stop() {
        guard let process = lock.withLock({ self.process.take() }), process.isRunning else {
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

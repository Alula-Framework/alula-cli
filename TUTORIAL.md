# Building an Alula application

A checkpoint-driven walkthrough that builds one application in three parts.
Each part ends at a project you can download and run — the same three the
starter site offers:

| Part | Ends at | You will have built |
|---|---|---|
| **1** | [`templates/skeleton`](templates/skeleton) | Configuration, dependency injection, HTTP, health endpoints |
| **2** | [`templates/basics`](templates/basics) | Entities, migrations, a repository, CRUD over Postgres |
| **3** | [`templates/demo`](templates/demo) | Real-time chat: PubSub, Channels, Presence, caching, authentication |

Every stage ends with a **Checkpoint** — a command and what you should see.
Don't move on until it passes; every later stage assumes the earlier ones.

The three templates are not three separate samples. Part 1's files are a
subset of Part 2's, and Part 2's a subset of Part 3's — checked mechanically
in CI. That is what lets each stage below be a real diff rather than prose
that drifts from the code. If a stage and its template ever disagree, the
template is right and the tutorial has a bug.

## What you need

- Swift 6.3 or later (`swift --version`)
- On macOS: the macOS 26 SDK (Xcode 26). The project you generate depends on
  `alula`, which needs it to compile — though what it produces still runs on
  macOS 15. On Linux there is nothing extra.
- Docker, from Part 2 onward, for Postgres
- No prior Alula knowledge; some Swift concurrency will help in Part 3

## The shape of an Alula application

Three ideas carry most of the framework, and they are worth having in mind
before any code:

**Registration happens at build time.** A build plugin scans your target for
`@Controller`, `@Service`, `@Repository`, and `@Component`, and generates the
registration code. Adding a controller does not mean editing a list. A
misspelled configuration key is a compile error, not a 3am page.

**Composition is by module, and modules form a DAG.** You choose behaviour by
adding a module to the list `main` composes, and the framework orders them.
A module is a value: what it needs arrives in its initializer, and what it
offers the rest of the application is a property on it. Choosing an
HTTP transport is choosing a module. So is adding a database, a cache, or
authentication.

**Borrowing is explicit.** Components are singletons. A repository holds the
*pool* and leases a connection for exactly one operation — `withRepo` is that
bracket, and the borrow ends when it returns. Statements that must share a
connection, and therefore a transaction, go inside one bracket together, so
"which connection is this query on?" is answered by code you can see rather
than by a scope you cannot.

---

# Part 1 — The skeleton

## Stage 1.1 — A package

If you have the CLI, `alula new MyService` writes everything in this part for
you and you can skip to Stage 1.5's checkpoint. Doing it by hand once is worth
it — the rest of the tutorial assumes you know what each piece is for.

Create a directory and a `Package.swift`:

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alula-Framework/alula.git",
                 from: "0.43.0", traits: ["Web"])
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "AlulaCore", package: "alula"),
                .product(name: "AlulaWeb", package: "alula"),
                .product(name: "AlulaTransport", package: "alula"),
                .product(name: "AlulaActuator", package: "alula"),
            ],
            plugins: [
                .plugin(name: "AlulaRegistrationPlugin", package: "alula")
            ]
        )
    ]
)
```

One package dependency gives you four products. `alula` is a single package
with many library products, so you take what you use — and `traits: ["Web"]`
says which of its optional layers you want. Nothing you do not name gets
resolved: the authentication stack and its JWT dependencies are simply absent
from this project.

**`AlulaTransport` deserves a note.** Alula Web owns routing, middleware,
and the request/response model; it does not own a socket. `AlulaTransport`
is the default transport, wrapping HummingbirdCore — a mature, versioned HTTP
implementation. Alula does not hand-roll HTTP parsing, and any conforming
transport is a peer of this one.

**The plugin is not optional decoration.** It scans your sources and generates
the composition root from what it finds — `alulaComposeModules`, which builds
your modules in dependency order, and `alulaRoutes`, which turns every
`@GetRoute` into a route value. It also checks your `@ConfigValue` keys against
`alula.yaml` at build time.

### Checkpoint

```bash
swift build
```

Downloads the framework and succeeds with no targets to compile yet.

## Stage 1.2 — Configuration

Create `alula.yaml` beside `Package.swift`:

```yaml
app:
  name: App

server:
  host: 127.0.0.1
  port: 8080

actuator:
  format: json
```

Alula Config layers sources: this file, then `ALULA_*` environment
variables over it, then anything a module contributes. The result is frozen
into an immutable `Configuration` at bootstrap. **Nothing re-reads this file
at runtime** — a configuration value cannot change under a running request,
which is why `Configuration` is safe to hold anywhere.

`ALULA_SERVER_PORT=9090 swift run App` overrides the port without editing
the file. The mapping is mechanical: dots become underscores, uppercased.

## Stage 1.3 — Bootstrap

Create `Sources/App/Main.swift`:

```swift
import AlulaActuator
import AlulaCore
import AlulaTransport
import AlulaWeb

/// Your application's module: one place that says what this app is made of.
struct AppModule: AlulaModule {
    static var dependencies: [any AlulaModule.Type] { [] }
}

@main
struct Main {
    static func main() async {
        await Alula.run(
            configuration: try Configuration.load(),
            modules: [
                AlulaWebModule<AlulaTransport>.self,
                AppModule.self,
                ActuatorModule.self,
            ],
            composedBy: alulaComposeModules
        )
    }
}
```

**`AppModule` has no body, and that is the point.** It names the subsystems
this application is built on — nothing, so far — and nothing else. Every
`@Controller`, `@Service`, `@Repository`, and `@Component` in your sources is
found by the plugin and wired by the generated composition root, so adding a
controller never means editing this file.

`alulaComposeModules` does not exist in any file you wrote — the plugin
generates it from the `modules:` list, and it constructs each module in
dependency order. That is what lets a module *take* what it needs in its
initializer. Without the argument, Alula would have to instantiate each module
from its type, which is why one would then have to be constructible with no
arguments at all.

`main` is `async`, not `async throws`, and that is worth a sentence. An error
that escapes `main` is reported by the Swift runtime as "Fatal error: Error
raised at top level", followed by a register dump and a backtrace. The two
startup failures you will actually hit — Postgres not running, port 8080
already bound — are not crashes and should not look like them. `Alula.run`
prints the reason and exits 1; it is `bootstrap` plus that difference, and an
embedder that wants the error rather than the exit calls `bootstrap` directly.

What `run` does, in order: load configuration, compose the modules in
dependency order, build every component **once**, then start services.
Construction and use are separate phases, so nothing serves traffic against a
half-built graph, and a dependency that cannot be satisfied is a composition
error at startup naming what was missing — or, more often, a build error,
because most of that graph is checked when the plugin generates it.

### Checkpoint

```bash
swift run App        # serves until you press Ctrl-C
```

Starts and logs its bound address. `curl localhost:8080/actuator/health`
returns JSON. Every route 404s, because you have not written one. Ctrl-C.

## Stage 1.4 — A route

Create `Sources/App/Controllers/HealthController.swift`:

```swift
import AlulaCore
import AlulaWeb

@Controller
struct HealthController {
    @ConfigValue("app.name") var appName: String

    @GetRoute("/")
    func index(_ context: RequestContext) -> String {
        "\(appName) is flying"
    }
}
```

Nothing registers this controller by hand. The plugin found it.

`@ConfigValue` with no `default:` is checked at **build** time against
`alula.yaml`. Try misspelling it as `app.nmae` and rebuild: the build fails
naming the key. That check is the reason to prefer `@ConfigValue` over
reading `Configuration` directly.

### Checkpoint

```bash
swift run App &
curl -sf --retry 30 --retry-connrefused --retry-delay 1 localhost:8080/actuator/health
curl localhost:8080/          # → App is flying
curl localhost:8080/actuator/health
kill %1
```

That first `curl` is not ceremony. `swift run` builds before it runs, so the
first time through, an immediate request fires while the compiler is still
working and gets connection refused. `--retry-connrefused` waits for the
server to bind and gives up after thirty tries rather than hanging forever —
a health check that never fails is not a health check.

Waiting on `/actuator/health` specifically is the reason the actuator
registers a probe by default even outside development: this is the same thing
an orchestrator does before routing traffic to a new instance.

## Stage 1.5 — A test

Create `Sources/App/Entities/`, `Sources/App/Repos/`, and
`Sources/App/Services/` now. Part 2 fills the first two. `Services/` stays
empty until Part 3, and that is deliberate — see
[Where the service layer goes](#where-the-service-layer-goes) at the end of
Part 2 for why a CRUD controller talking straight to a repository is the right
shape until it is not.

Add the test target to `Package.swift`:

```swift
.testTarget(
    name: "AppTests",
    dependencies: [
        "App",
        .product(name: "AlulaCore", package: "alula"),
        .product(name: "AlulaWeb", package: "alula"),
        .product(name: "AlulaWebTesting", package: "alula"),
    ]
)
```

And `Tests/AppTests/HealthControllerTests.swift`:

```swift
import AlulaCore
import AlulaWeb
import AlulaWebTesting
import Testing

@testable import App

@Suite("Health route")
struct HealthControllerTests {
    @Test("the index route answers with the configured application name")
    func index() async throws {
        // The composition root's sequence, by hand: build the graph, then the
        // routes from it — the values `AlulaWebModule` is composed with.
        let configuration = Configuration(values: ["app.name": "TestApp"])
        let graph = try AlulaGraph(configuration: configuration)
        let client = try TestClient(routes: alulaRoutes(graph))

        let response = await client.get("/")

        #expect(response.status == .ok)
        #expect(response.bodyText == "TestApp is flying")
    }
}
```

Two generated things appear here, and they are the same two the application
uses. `AlulaGraph` is every component, built once from its roots —
`Configuration` is the only root this tier has. `alulaRoutes(graph)` is every
route in the target, built from that graph. `main` composes them through
`AlulaWebModule`; the test hands them to a `TestClient` instead. Nothing is
mocked, and nothing test-only is involved in either.

`TestClient` dispatches **in process**. There is no socket and no port to
collide with, but routing, middleware, dependency injection, configuration,
and encoding all run for real. Tests are fast because the socket is absent,
not because the framework is stubbed.

### Checkpoint

```bash
swift test        # 1 test passes
```

**You have now built [`templates/skeleton`](templates/skeleton).** Compare if
you like — it should match file for file.

---

# Part 2 — Persistence

Part 1's application holds no state. This part gives it a database, and
introduces the three pieces that surround one: entities, migrations, and
repositories.

## Stage 2.1 — A database to talk to

```bash
docker run -d --name alula-postgres \
  -e POSTGRES_PASSWORD=alula -e POSTGRES_DB=app_dev \
  -p 55432:5432 postgres:16
```

Port 55432 rather than 5432, deliberately: a starter project should not fight
whatever is already on the default port.

Add to `alula.yaml`:

```yaml
datasource:
  primary:
    url: "postgres://postgres:alula@127.0.0.1:55432/app_dev?sslmode=disable"
    pool_size: 5
```

`pool_size` is a real ceiling, not a hint. Every request that touches a
repository holds one connection for that request's whole life, so five is
five concurrent database-touching requests. Raise it, or shorten your units
of work — but know which one you are doing.

`sslmode=disable` is correct for a local container and wrong everywhere else.
Note that `require` does **not** verify certificates; `verify-full` does.

## Stage 2.2 — The package gains a database

```swift
dependencies: [
    .package(url: "https://github.com/Alula-Framework/alula.git",
             from: "0.43.0", traits: ["Web"]),
    .package(url: "https://github.com/Alula-Framework/alula-data.git",
             from: "0.14.0", traits: ["Postgres"]),
],
```

**That `traits:` argument is doing real work.** `alula-data` carries the
Postgres driver, the Valkey driver, the in-memory cache, and the data
protocols. Without the `Postgres` trait, PostgresNIO is not merely unused —
it is never resolved, never fetched, and never appears in your
`Package.resolved`. Add `"Valkey"` alongside it when you want that adapter
too.

Traits are opt-in throughout: this project resolves 34 packages, and neither
`valkey-swift` nor `jwt-kit` is among them, because nothing asked for them.
That is also why Alula requires Swift 6.3 — SwiftPM 6.2 could not resolve an
opt-in trait through a versioned dependency.

Add `AlulaDataPostgres` to the `App` target's dependencies, and two new
targets:

```swift
.target(
    name: "Migrations",
    dependencies: [.product(name: "AlulaMigrate", package: "alula-data")],
    plugins: [.plugin(name: "AlulaMigratePlugin", package: "alula-data")]
),
.executableTarget(
    name: "migrate",
    dependencies: [
        "Migrations",
        .product(name: "AlulaMigrateCLI", package: "alula-data"),
    ]
),
```

Migrations live in their own target, and **the app target does not depend on
it**. Migrations are something you run, not something your server does while
booting. A server that migrates on startup is a server that races itself when
you run two of them.

## Stage 2.2b — The same thing, with the CLI

Stage 2.2 added the two migration targets by hand, because it is worth seeing
what they are once. From here on the CLI does it:

```bash
alula migrate init
```

In a project with no migration targets it writes `Sources/migrate/Migrate.swift`,
creates `Sources/Migrations/` with a placeholder so the target has a module to
build, and inserts both targets plus the `alula-data` dependency into
`Package.swift`. In a project that already has them it says so and changes
nothing.

Every other migration command is the same tool you already have, reached
through `alula` instead of `swift run`:

| | |
| --- | --- |
| `alula migrate` | apply everything pending |
| `alula migrate status` | what is applied, what is not |
| `alula migrate status --json` | the same, machine-readable |
| `alula migrate create AddPosts` | write a new timestamped migration |
| `alula migrate rollback` | revert the last one |
| `alula migrate rollback --steps 3` | revert the last three |
| `alula migrate rollback --to 20260101000000` | revert down to a version |
| `alula migrate repair` | re-checksum a migration you edited |
| `alula migrate --dry-run` | print the SQL without running it |
| `alula migrate --help` | every option |

Arguments are passed straight through, so anything the underlying tool accepts
works here.

**Why it builds your project first.** Migrations are Swift types in your
package, found at build time. A globally installed binary cannot know what
`CreateUsers.up(_:)` does, so `alula migrate` builds and runs your project's
own migrate executable. The first run of a session pays for a build; the rest
are instant.

The connection URL comes from `--database-url`, then `$ALULA_DATABASE_URL`,
then `$DATABASE_URL` — never from `alula.yaml`, so a migration tool is always
explicit about which database it is about to alter.

This tutorial keeps using `swift run migrate` so it works with or without the
CLI installed. They are the same commands.

## Stage 2.3 — An entity

`Sources/App/Entities/User.swift`:

```swift
import AlulaDataPostgres
import AlulaWeb
import Foundation

@Entity("users")
struct User: Encodable, Equatable, Sendable, ResponseEncodable {
    @ID var id: UUID
    var name: String
    var email: String
    @Column("createdAt") var createdAt: Date
    @Column("updatedAt") var updatedAt: Date
}
```

`@Entity` generates a typed column set. Queries are checked at compile time:
`User.where { $0.emial == x }` does not compile, and neither does comparing a
`String` column to an `Int`. A typo is a build error rather than a runtime
surprise or, worse, a query that silently matches nothing.

`@Column` is needed only where the Swift name and the SQL name differ.

Note what `User` is **not**: `Decodable`. Entities go out as JSON; what comes
back in should be a request type of its own. Once an association has crossed
the wire as `null`, "not loaded" and "loaded and empty" are indistinguishable,
and the type refuses to guess between them.

## Stage 2.4 — A migration

```bash
ALULA_DATABASE_URL=postgres://postgres:alula@127.0.0.1:55432/app_dev \
  swift run migrate create CreateUsers
```

That writes a timestamped file into `Sources/Migrations`. Fill it in:

```swift
import AlulaMigrate
import Foundation

struct CreateUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("users") { t in
            t.uuid("id").primaryKey().default(.generatedUUID)
            t.varchar("name", limit: 30).notNull()
            t.varchar("email", limit: 50).notNull().unique()
            t.timestamptz("createdAt").notNull().default(.now)
            t.timestamptz("updatedAt").notNull().default(.now)
        }
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}
```

Two things worth internalising:

**Column names must match the entity exactly.** Property names map to columns
with no case conversion, so a convenience helper emitting `created_at` would
silently miss `createdAt`. Spell them out.

**Every migration says how to undo itself.** That is what makes `migrate rollback`
something you run rather than something you fear.

Applied migrations are checksummed. Edit one that has already run and the
tool tells you, rather than letting your database and your code quietly
disagree.

### Checkpoint

```bash
export ALULA_DATABASE_URL=postgres://postgres:alula@127.0.0.1:55432/app_dev
swift run migrate status       # one pending
swift run migrate              # applies it — `apply` is the default subcommand
swift run migrate status       # one applied
swift run migrate rollback     # reverts it
swift run migrate              # and forward again
```

The subcommands are `apply` (the default, so bare `migrate` applies),
`status`, `rollback`, `create`, and `repair`. `migrate --help` lists every
option.

The CLI reads `ALULA_DATABASE_URL`, not `alula.yaml` — a migration tool
should be explicit about which database it is about to alter.

## Stage 2.5 — A repository, and the seam in front of it

Two files. First the seam, `Sources/App/Repos/UserRepositoryProtocol.swift`:

```swift
import AlulaDataPostgres
import Foundation

protocol UserRepositoryProtocol: Sendable {
    func all() async throws -> [User]
    func find(byID id: UUID) async throws -> User?
    func find(byEmail email: String) async throws -> User?
    func create(name: String, email: String) async throws -> User
}
```

Then the implementation, `Sources/App/Repos/UserRepository.swift`:

```swift
import AlulaDataPostgres
import Foundation

@Repository
struct UserRepository: UserRepositoryProtocol {
    // alula:hand-registered — PostgresDataModule registers the pool.
    @Inject var pool: PostgresDataSource

    func all() async throws -> [User] {
        try await pool.withRepo { repo in
            try await repo.all(User.all.order { $0.createdAt.desc() })
        }
    }

    func find(byID id: UUID) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(User.where { $0.id == id })
        }
    }

    func find(byEmail email: String) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(User.where { $0.email == email })
        }
    }

    func create(name: String, email: String) async throws -> User {
        let now = Date()
        return try await pool.withRepo { repo in
            try await repo.insert(
                User(id: UUID(), name: name, email: email, createdAt: now, updatedAt: now))
        }
    }
}
```

**Why the protocol?** A struct wrapping a live database scope cannot be
swapped out. A protocol can. That is the entire reason Stage 2.7's tests can
run the real controller — and, where it is the point, the real routing and
encoding — with no database in the loop. Depend on the protocol everywhere;
the composition root is the one place that names the concrete type.

**Why hold the pool rather than a connection?** Because the borrow is then
visible. `withRepo` leases for the length of its closure and returns the
connection when it ends, so a slow handler holds one only while it is actually
querying, and two statements share a connection exactly when you put them in
one bracket. A repository that held a connection for the whole request made
"how long is this borrowed for?" a question about a scope somewhere else.

Finally, say that this application is built on Postgres — in `Main.swift`:

```swift
static var dependencies: [any AlulaModule.Type] {
    [PostgresDataModule<PrimaryDataSource>.self]
}
```

That one line is what puts the pool in the component graph, which is what lets
`@Inject var pool: PostgresDataSource` above resolve. It also gives the graph a
second root, so `HealthControllerTests` from Stage 1.5 grows a line: build the
Postgres module, and pass its `dataSource` to `AlulaGraph`. Building the
module opens no connection — but `datasource.primary.url` must now exist in the
test's `Configuration`, which is the point. A missing key fails at startup
rather than at the first request that needed it. The updated file is in
[`templates/basics`](templates/basics/Tests/AppTests/HealthControllerTests.swift).

## Stage 2.6 — Routes

`Sources/App/Controllers/UserController.swift`:

```swift
@Controller
struct UserController {

    /// A controller is constructed per request from the component graph, so
    /// what it needs is a property the build wires — visible in the type,
    /// checked when the application is composed, and with no per-request
    /// lookup that could fail.
    @Inject var users: (any UserRepositoryProtocol)

    @GetRoute("/users")
    func list(_ context: RequestContext) async throws -> [User] {
        try await users.all()
    }

    @GetRoute("/users/:id")
    func get(_ context: RequestContext, id: UUID) async throws -> User {
        guard let user = try await users.find(byID: id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        return user
    }

    @PostRoute("/users")
    func create(_ context: RequestContext, body: CreateUserRequest) async throws -> Response {

        let changeset = Changeset(User.self)
            .change(\.name, body.name)
            .change(\.email, body.email)
            .validate(\.email, .email)
        guard changeset.isValid else {
            throw HTTPError(.badRequest, "invalid user: \(changeset.errors)")
        }
        guard try await users.find(byEmail: body.email) == nil else {
            throw HTTPError(.conflict, "that email is already registered")
        }
        return try .json(await users.create(name: body.name, email: body.email), status: .created)
    }
}
```

Handlers stay thin on purpose: resolve, delegate, translate failures into
status codes. The controller is the only layer that should know what a 404 is;
the repository is the only layer that should know SQL.

**Changesets run before SQL does.** A changeset collects changes, validates
them, and only a valid one reaches the database. An invalid email never
becomes a query.

The full file, including `CreateUserRequest`, is in
[`templates/basics`](templates/basics/Sources/App/Controllers/UserController.swift).

### Checkpoint

```bash
swift run App &
curl -sf --retry 30 --retry-connrefused --retry-delay 1 localhost:8080/actuator/health
curl -XPOST localhost:8080/users -H 'content-type: application/json' \
     -d '{"name":"Ada","email":"ada@example.com"}'          # → 201
curl localhost:8080/users                                    # → [Ada]
curl -XPOST localhost:8080/users -H 'content-type: application/json' \
     -d '{"name":"Nope","email":"nonsense"}'                 # → 400
curl -XPOST localhost:8080/users -H 'content-type: application/json' \
     -d '{"name":"Ada 2","email":"ada@example.com"}'         # → 409
kill %1
```

## Stage 2.7 — Testing without a database

This is what the dependency injection was for.

`UserController` depends on `(any UserRepositoryProtocol)` rather than on
`UserRepository`, and `@Controller` generates an initializer over the injected
properties. Those two facts together mean the default test needs no framework
at all: a controller is a struct, a route is one of its methods, so the test
constructs the type with a fake and calls the method.

```swift
let controller = UserController(users: InMemoryUsers([ada]))

let listed = try await controller.list(.mock())
#expect(listed.map(\.name) == ["Ada"])
```

`UserController(users:)` is the whole setup. Nothing is registered and nothing
is looked up — wiring the real repository in is the composition root's job, and
a unit test is exactly the place that does it by hand instead. The macro only
*adds* members; it never rewrites your method, so the thing under test is the
code you wrote.

`RequestContext.mock(...)` builds a context with no transport behind it: path
parameters, headers and a body when the handler needs them, nothing when it
does not.

```swift
let user = try await controller.get(.mock(), id: ada.id)
#expect(user.email == ada.email)
```

**Notice what that asserts on.** `get` returns a `User` — the domain value,
which is the handler's actual decision — not a `Response`. Turning it into JSON
and choosing a status happens at the route boundary, so this tier never sees a
status code and does not need one to prove the right user came back.

Failures are just as direct. A thrown `HTTPError` is assertable without HTTP,
so proving *why* a request would 404 costs nothing:

```swift
await #expect(throws: HTTPError.self) {
    _ = try await controller.get(.mock(), id: UUID())
}
```

Notice which test is *missing* here: there is none for "the id was not a
UUID". `id: UUID` is a parameter, so a malformed one cannot reach this
handler and cannot be written into this test. That check belongs to the
route, which refuses it before the handler runs — and the end-to-end tier
asserts it there, because that is the only level at which it can happen.

A fake is just a type that conforms. There is no mock framework and nothing
generated:

```swift
final class InMemoryUsers: UserRepositoryProtocol, Sendable {
    private let users = Mutex<[User]>([])
    var stored: [User] { users.withLock { $0 } }
    ...
}
```

Because it is a real object, a test can interrogate it afterwards — which is
how you assert on effects rather than only on what came back:

```swift
let users = InMemoryUsers()
await #expect(throws: HTTPError.self) {
    _ = try await UserController(users: users).create(
        .mock(), body: CreateUserRequest(name: "Nope", email: "not-an-email"))
}
#expect(users.stored.isEmpty, "validation must run before the write")
```

That last line is the one worth copying. It proves validation ran *before* the
write — a claim about order that no return value could make.

### The tier those calls deliberately skip

A direct call never proves that a path routes, a body decodes, a return value
encodes, or a thrown error becomes the right status. None of that is visible to
a method call, and none of it needs repeating per handler. A few representative
paths prove the plumbing once:

```swift
let users = InMemoryUsers([ada])
let client = try TestClient(
    routes: UserController.alulaRoutes { _ in UserController(users: users) })

let response = await client.get("/users/\(ada.id)")

#expect(response.status == .ok)
#expect(response.headers[.contentType]?.contains("json") == true)
#expect(try response.decodeJSON(UserPayload.self).email == ada.email)
```

`TestClient` dispatches **in process**: routing, middleware, request decoding
and JSON encoding all run for real, but there is no socket and no port to
collide with. These tests are fast because the network is absent, not because
the framework is stubbed.

`alulaRoutes` is generated alongside the per-route factories and returns all
of them, so nothing here names a route by position — add a route to the
controller and this keeps working unchanged. The closure *is* the injection:
it builds the controller per request, which is where the fake goes in.

This is also the only tier with a response to inspect, which is why the
error-to-status mapping is proved here and nowhere else:

```swift
#expect(await client.get("/users/not-a-uuid").status == .badRequest)
#expect(await client.get("/users/\(UUID())").status == .notFound)
```

Decode into a small payload type rather than back into `User`. Entities are
`Encodable` but deliberately not `Decodable` (Stage 2.3), and a payload type
also states what this endpoint is *supposed* to return:

```swift
private struct UserPayload: Decodable {
    let id: UUID
    let name: String
    let email: String
}
```

### Four sizes of test

| | What runs | Reach for it when |
|---|---|---|
| Call the method | one handler, one fake | most of the time |
| `TestClient` + `alulaRoutes` | real routing, middleware, decoding, encoding, error mapping | proving the plumbing once, not once per handler |
| A real database | the query itself | the SQL is the claim |
| Compose the modules | every module the application builds | the wiring itself is the claim |

**The third row is the honest one.** `UserRepository` is built on Hangar's
`Repo`, which talks to a real connection; there is no seam underneath it to
slot a fake into, and a fake that rendered no SQL would prove nothing about
SQL. A test that a query renders and runs correctly needs a real database, the
same way Hangar's own suite does. That is precisely why the seam is one layer
up: everything above `UserRepositoryProtocol` is testable with no database, and
the one type below it is the one that needs a throwaway server.

**The fourth catches what the other three cannot**, because building the graph
is where a composition mistake surfaces — a module initializer that throws on
real configuration, say. A test that never composes cannot see it. (Two
modules providing one type is not in this category: the generator refuses it
and the build fails, so no test ever gets the chance.)

```swift
let configuration = Configuration(values: [
    "app.name": "TestApp",
    "datasource.primary.url": "postgres://localhost/unused",
])
let postgres = try PostgresDataModule<PrimaryDataSource>(configuration: configuration)
// Building the graph *is* the assertion: every component is constructed here,
// eagerly, so a component that cannot be built fails on this line.
_ = try AlulaGraph(
    configuration: configuration, postgresDataSource: postgres.dataSource)
_ = try Alula.assemble(
    configuration: configuration, modules: [postgres, AppModule()])
```

Nothing dials Postgres in that test — building the module opens no connection —
but every key it needs must exist, which is the point. The demo carries a
`BootstrapTests` suite that does nothing else, for exactly this reason.

The complete suite is in
[`templates/basics`](templates/basics/Tests/AppTests/UserControllerTests.swift),
and the fake is in
[`InMemoryUsers.swift`](templates/basics/Tests/AppTests/InMemoryUsers.swift).

### Checkpoint

```bash
swift test        # 11 tests pass, no database required
```

## Where the service layer goes

`Sources/App/Services/` is still empty, and `UserController` injects the
repository directly. That is on purpose.

A service exists to hold behaviour that belongs to neither neighbour — a
controller should only translate HTTP, and a repository should only know SQL.
Everything this application does so far is one query per request, so a service
here would be a class of forwarding methods:

```swift
// What a service would look like at this point. Don't write this.
func all() async throws -> [User] { try await repository.all() }
```

That layer costs a file, an indirection, and a registration, and buys nothing.
Add it when there is something to put in it — which Part 3 reaches almost
immediately:

```swift
@Service
struct UserService {
    @Inject var repository: (any UserRepositoryProtocol)

    func signup(name: String, email: String) async throws -> User {
        // Validate, then hand one unit of work to the repository, which
        // opens the transaction around both writes: it either wholly happens
        // or wholly does not.
    }
}
```

Validation, a transaction spanning two writes, and a rule about what signing
up *means* — none of that is HTTP and none of it is SQL. That is a service.

The empty directory is a signal, not an oversight: it is where behaviour goes
when you have some.

**You have now built [`templates/basics`](templates/basics).**

---

# Part 3 — Real time

Part 2's application answers questions. This part makes it push — a chat room
where messages arrive live, you can see who else is in the room, and both are
correct across a cluster rather than only on one machine.

Four layers arrive here, and they stack:

| Layer | Owns |
|---|---|
| **PubSub** | Fan-out. Publish to a topic; subscribers get it, on one node or twenty |
| **Channels** | The per-connection protocol over a WebSocket: join, events, replies, heartbeats |
| **Presence** | "Who is in this topic", CRDT-merged across the cluster |
| **Security** | Turning a token into a `Principal`, and the guards that check one |

Part 3 is longer than the first two together, so it is split by concern.
[`templates/demo`](templates/demo) is the finished result at every point.

## Stage 3.1 — The chat schema

The demo's schema adds rooms, messages, topics, and a join table. The
migrations are in
[`templates/demo/Sources/Migrations`](templates/demo/Sources/Migrations) — copy
them into `Sources/Migrations/` and apply them with `swift run migrate`.

The shapes worth noticing, because Part 3 leans on all of them:

- `messages.roomID` — an ordinary foreign key, giving a has-many.
- `messages.authorID` — **nullable**, so the association is over an optional
  key. A message from someone who never registered belongs to nobody.
- `messages.parentID` — a self-reference, read with an aliased self-join.
- `messages.mentions` — a Postgres `text[]`, which needs nothing special:
  `Column<[String]>` falls out of the ordinary generic path.

## Stage 3.2 — Authentication, brought rather than built

Alula Security Core is a **resource server**. It validates tokens somebody
else issued. There is no login form, no session table, and no password
hashing anywhere in it — that is deliberate, and it is the single most
important thing to understand about this layer.

The seam is one protocol:

```swift
public protocol TokenValidator: Sendable {
    func validate(_ token: String) async throws -> Principal
}
```

The shipped implementation is a generic OIDC validator that any compliant
provider — Keycloak, Auth0, Okta, Entra, Descope — is *configuration* of, not
a fork of. Two keys are usually enough:

```yaml
security:
  oidc:
    issuer: https://your-tenant.example.com/
    audience: your-app
```

Signature verification delegates to JWTKit. Alula owns orchestration only.

For a tutorial that runs with no identity provider, the demo supplies its own
validator instead —
[`DemoTokenValidator`](templates/demo/Sources/App/Security/DemoTokenValidator.swift),
which accepts `demo:ada:moderator` and does no cryptography at all. A module
provides it as a value:

```swift
struct DemoAuthModule: AlulaModule {
    let tokenValidator: any TokenValidator = DemoTokenValidator()
}
```

`AlulaSecurityModule` takes one — `init(validator:)` — and the composer
matches that property to that parameter **by type**. So there is no ordering to
get right and no "first registration wins" to reason about: a validator is
either provided or the build says that nothing provides one. Listing
`AlulaOIDCModule` instead is the same mechanism with `security.oidc.*` behind
it, which is what a real deployment does.

It is its own module rather than a property on `AppModule`, and the reason is
worth a sentence: `SocketController` injects the validator, which makes it a
*root* of the component graph — and the graph is built before the modules that
are built from it. A module that both takes the graph and provides one of its
roots would be a cycle, and the build refuses that by name.

That is the bring-your-own-auth seam, and the demo file exists to show it.
**Delete it in anything real** and configure `security.oidc.*`. Rolling your
own token format is exactly the mistake this layer is shaped to prevent; the
demo gets away with it only because its tokens grant access to a chat room on
your laptop.

Guarding a route is a line in the handler:

```swift
try context.requireRole("moderator")
```

401 with no principal, 403 with the wrong one. The alternative is a guard every
route passes through, which protects *everything* — right for an internal
service, wrong for an app whose reads are public. Middleware is values too:
`AlulaSecurityModule` puts `Authentication` on the default lane, so a
principal is established for every request, and pairs it with
`RequireAuthentication` on the lane that demands one. Establishing identity and
insisting on it are two decisions, and the module keeps them separate.

## Stage 3.3 — A channel

A `Channel` is per-topic server logic. Joining creates one instance per
(socket, topic), so one declaration serves every room. A module *holds* its
channels as a value:

```swift
struct DemoChannelsModule: AlulaModule {
    static var dependencies: [any AlulaModule.Type] { [AlulaChannelsModule.self] }

    let channels: [ChannelRegistration]

    init(graph: AlulaGraph, presence: any Presence) {
        let chat = graph.chatRepository
        let digests = graph.roomDigestService
        self.channels = [
            // The broadcaster arrives per join, in the `ChannelContext`:
            // Channels owns it and is built *from* this module, so it cannot
            // be a construction-time dependency without a cycle. Everything
            // else is closed over.
            ChannelRegistration("room:*", source: "DemoChannelsModule") { channel in
                RoomChannel(
                    broadcaster: channel.broadcaster,
                    presence: presence,
                    chat: chat,
                    digests: digests)
            }
        ]
    }
}
```

The composition root collects `channels` from every module that declares any
and hands them to `AlulaChannelsModule`, which builds its router from them —
so a malformed or duplicate pattern fails at composition rather than at a join,
and a package outside your application can contribute channels without you
listing them anywhere.

Its own module again, and for the same reason as `DemoAuthModule`: the socket
route injects the channels stack, which makes that a graph root, and a module
that provides a root cannot also take the graph. Taking the graph is legal
*here* precisely because the graph does not depend on Channels — what only a
route terminal needs is passed to the terminals instead of stored on the graph.
Without that split this module could not exist.

The socket itself is a route, so it is declared like one, in
[`SocketController.swift`](templates/demo/Sources/App/Controllers/SocketController.swift):

```swift
@Controller
struct SocketController {
    // The marker says the scanner is right not to have found these: both are
    // provided by a module rather than scanned from an annotation here.
    // alula:hand-registered
    @Inject var validator: any TokenValidator
    // alula:hand-registered
    @Inject var sockets: ChannelSockets

    @WebSocketRoute("/socket")
    func socket(_ context: RequestContext) async throws -> ChannelSocketHandler {
        var principal: (any ChannelPrincipal)?
        if let token = context.request.queryParam("token") {
            principal = try? await validator.validate(token)
        }
        return sockets.handler(principal: principal)
    }
}
```

**Identity is established during the HTTP upgrade**, before the WebSocket
exists — while there is still an HTTP response to fail with. The token
arrives as a query parameter because browsers cannot set headers on a
WebSocket handshake. An anonymous socket is admitted deliberately, and every
`join` below then rejects it.

**The channels stack arrives as one injected value**, rather than being
assembled per upgrade. It used to be built from the request context, which
meant looking up the router, the bus and the channels configuration on every
upgrade — three lookups, on every connection, of things the composition root
has held since start-up.

A module could build the same route by hand, as a `RouteRegistration` value
handed to `AlulaWebModule`, and it would work. Prefer the declared form in an
application: a value assembled at run time cannot be enumerated at compile
time, so a socket wired that way is absent from the static route manifest the
build emits. `@WebSocketRoute` keeps it on the map, and its dependencies are
visible in the type rather than discovered when the closure runs.

The channel itself, abridged from
[`RoomChannel.swift`](templates/demo/Sources/App/Channels/RoomChannel.swift):

```swift
func join(_ topic: String, socket: Socket) async -> JoinResult {
    guard let principal = socket.principal else { return .reject(.unauthenticated) }
    guard let slug = Self.roomSlug(from: topic) else {
        return .reject(JoinRejection("malformed_topic"))
    }
    guard let room = try? await chat.room(slug: slug, messageLimit: 0), !room.archived else {
        return .reject(JoinRejection("no_such_room"))
    }

    await presence.track(topic: topic, key: principal.subject,
                         payload: ["status": "online"], socket: socket)
    await presence.sendState(topic: topic, to: socket)

    return .ok(initialState: ["room": .string(room.slug)])
}
```

**The join is the authorization gate.** By the time an application frame can
arrive, the question of who this is has already been settled.

Note `roomSlug` refusing `"room:"`. Dropping the prefix leaves an empty
string, and treating that as a room named `""` would create presence lists for
a room nobody can name. Refuse rather than coerce.

## Stage 3.4 — Ordering, and the bug it prevents

Handling a message is short, and the order of two lines is the whole lesson:

```swift
let stored = try await chat.post([message])       // 1. persist

await broadcaster.broadcast(                       // 2. then fan out
    topic: event.topic, event: "new_msg",
    payload: Self.wire(stored.first ?? message),
    excluding: socket)

return .reply(Self.wire(stored.first ?? message))
```

A message that fans out to twenty subscribers and *then* fails to insert has
been read by everyone and exists for no one, and no retry puts that back.
Writing first means the worst case is a message that is durable but arrives
late — which the client's next history fetch repairs on its own.

`excluding: socket` keeps the sender from seeing their own message twice:
they get the canonical row as the reply, so the broadcast is for everybody
else.

**Fan-out is PubSub's job, not the channel's.** That `broadcast` reaches
subscribers on every node in the cluster; this code never learns how many
nodes there are. Anything holding a `ChannelBroadcaster` can call it — a
handler, a background job, another node. The demo's REST `POST /messages`
does exactly that, so a message posted over HTTP reaches everyone currently
watching over a socket:

```swift
// `@Inject var broadcaster: ChannelBroadcaster` on the controller — the
// composition root wires it, like everything else a handler needs.
for message in stored {
    await broadcaster.broadcast(topic: "room:\(message.room)",
                                event: "new_msg", payload: RoomChannel.wire(message))
}
```

Two write paths, one wire shape, one `wire(_:)` function producing it. If
those ever diverge, clients see the same message in two shapes depending on
how it was sent.

## Stage 3.5 — Presence

Presence answers "who is here" for the whole cluster, merged with a CRDT — so
reordered or duplicated gossip is harmless and replicas converge with no
leader, no locks, and no synchronized clocks.

Two calls in `join` were all it took, and there is **no matching call to
remove anyone**. Tracking is bound to the socket's membership of the topic, so
every teardown path — client leave, dropped transport, heartbeat timeout,
server shutdown — untracks structurally. There is nothing to remember.

One identity can be present many times: three browser tabs are one **key**
with three **metas**. Closing one tab removes one meta and leaves the person
present. Collapsing that to a list of names would lose the distinction the
whole data structure exists to keep, which is why the demo's
`GET /rooms/:slug/who` reports a connection count alongside each name.

Clients get one `alula:presence_state` on join, then `alula:presence_diff`s.
Both reference clients maintain the list for you: `AlulaPresenceClient` in
Swift, `@alula-framework/channels/presence` in JavaScript.

## Stage 3.6 — Caching the expensive reads

Two of the demo's queries are worth caching — a `GROUP BY … HAVING` over every
message, and a `DISTINCT ON` across every room. Both are expensive, both are
polled by dashboards, and both tolerate being a few seconds stale.

```swift
@Service
struct RoomDigestService {
    @Inject var chat: ChatRepository

    @Cacheable(namespace: "room_digest", ttl: .seconds(30))
    func activity(minimumMessages: Int) async throws -> [RoomActivity] {
        try await chat.activity(minimumMessages: minimumMessages)
    }

    @CacheEvict(namespace: "room_digest", allEntries: true)
    func messagesChanged() async {}
}
```

`@Cacheable` expands **into the method body**, not into a proxy wrapping the
type. That difference matters: a call from one method of this type to another
still goes through the cache, because there is no proxy to bypass. The
equivalent Spring footgun cannot occur here.

The cache coalesces: fifty concurrent misses on one key compute once and
forty-nine wait, rather than fifty queries hitting the database together.

Arguments are part of the key, so `?min=3` and `?min=10` are separate
entries. And **both** write paths — REST and WebSocket — call
`messagesChanged()`, because a cache the two paths disagree about is a cache
that lies to half your users.

`AlulaCacheModule` is in-memory by default. Swapping in Valkey is a module
change and a trait, not a code change.

## Stage 3.7 — Work on a schedule

Two of the things this app does are not requests. A nightly summary, and
keeping the expensive digests warm so the first dashboard load of the morning
is not the slow one.

Create `Sources/App/Jobs/ChatJobs.swift`:

```swift
@Scheduler
struct ChatJobs {
    @Inject var digests: RoomDigestService

    @Scheduled("0 0 3 * * *", timeZone: "UTC")
    func nightlySummary() async throws {
        let busy = try await digests.activity(minimumMessages: 10)
        print("nightly summary: \(busy.count) active room(s)")
    }

    @Scheduled(every: .minutes(1), initialDelay: .seconds(5), onEveryNode: true)
    func warmDigests() async throws {
        _ = try await digests.headlines()
    }
}
```

Add `AlulaSchedulerModule.self` to `AppModule.dependencies` and that is the
whole setup. Nothing registers `ChatJobs` by hand — the plugin found it, the
same way it found your controllers.

A `@Scheduler` type is an ordinary component. It injects with `@Inject`
like anything else, and its jobs are ordinary methods — so testing one needs
no scheduler, no clock and no database, exactly like testing a service:

```swift
private struct StubDigests: DigestReading {
    let rooms: [RoomActivity]

    func activity(minimumMessages: Int) async throws -> [RoomActivity] {
        rooms.filter { $0.messages >= minimumMessages }
    }
    func headlines() async throws -> [RoomHeadline] { [] }
}

@Test("the nightly summary runs against the busy rooms")
func summaryCountsBusyRooms() async throws {
    let jobs = ChatJobs(digests: StubDigests(rooms: [
        RoomActivity(room: "general", messages: 42, lastSentAt: Date()),
        RoomActivity(room: "quiet", messages: 1, lastSentAt: nil),
    ]))

    try await jobs.nightlySummary()
}
```

Constructed directly, and that is the whole point. `@Scheduler` — like
`@Controller` and `@Service` — generates an initializer over the injected
properties, so `ChatJobs(digests:)` is exactly what the composition root calls
when it builds this component from the graph, and exactly what the test calls
with a stub in place of the real service. Every component in this app is built
the same way for the same reason; see `ChatJobsTests`, which is the code above
in full.

Whether the job fires at 03:00 is the cron engine's business, and is tested
there rather than here.

Note that `ChatJobs` injects `(any DigestReading)` rather than
`RoomDigestService`. The concrete service carries a live cache and a repository
that needs Postgres; a three-method protocol needs neither. That is the same
seam `RoomStore` and `DigestInvalidating` exist for, and it is what makes the
test above two lines.

### The schedule is checked by the build

Change the hour to `25` and rebuild:

```
error: hour: 25 is out of range 0–23. In "0 0 25 * * *".
```

Not a job that silently never fires. The macro validates with the *same
parser the scheduler runs* — the cron engine is a separate, dependency-free
target that both import — so the build and the runtime cannot disagree about
what a schedule means.

Six fields, seconds first (`second minute hour day-of-month month
day-of-week`). The classic five-field crontab shape is accepted too and means
the same thing at second zero. `L`, `W`, `#`, `?` and `@daily` are **refused**
rather than guessed at: implementations disagree about what they mean, and a
schedule that quietly means something other than you intended is worse than
one that will not compile.

### The two kinds of job

This is the part worth slowing down for, and it is why there are two jobs here
rather than one.

`nightlySummary` runs **once**. Not once per server — once. On this demo that
is invisible, because there is one server. It stops being invisible the moment
there are two: a summary that emails, bills, or writes a report must not do it
three times.

`warmDigests` runs **on every server**, and says so. The demo's cache is
in-memory, so it is per-process: warming it on one server leaves the others
cold. That is work that is per-process by nature.

Note what the API does *not* ask you to know. There is no "cluster" anywhere
in the common case — `@Scheduled("0 0 3 * * *")` reads the same whether you
run one server or fifty, and the default is the safe one. `onEveryNode` shows
up only where it means something.

Swap `AlulaCacheModule` for the Valkey-backed one and `warmDigests` becomes
the wrong annotation, because a shared cache only needs warming once. Where
the state lives is what decides which kind a job is — that is a real design
question, not a detail.

### Running once when there really are several servers

`once` needs something for the servers to contend through. `AppModule` provides
one — it is in the demo already, because a job that is only safe on one machine
is not much of a demonstration:

```swift
struct AppModule: AlulaModule {
    let graph: AlulaGraph
    let jobCoordinator: any JobCoordinator

    init(graph: AlulaGraph) {
        self.graph = graph
        self.jobCoordinator = PostgresJobCoordinator(dataSource: graph.postgresDataSource)
    }
}
```

A property, matched by type to what `AlulaSchedulerModule` takes. Nothing
looks it up, which means a deployment cannot half-have one: the coordinator is
either provided or visibly absent.

The graph arrives the same way. `AppModule` takes it because everything this
application contributes is built from it — including the pool this coordinator
needs, which the graph has already built and which nothing else has to go
looking for.

It claims a lease row keyed on the job and the *firing instant*, so exactly
one server wins each firing — and two servers whose clocks differ by a second
still agree which firing they are contending for. On this single-process demo
it changes nothing observable, which is rather the point: the code you write
is the same either way.

Delete that property and the scheduler tells you at startup:

```
warning: 1 job(s) are set to run once per firing, and no distributed
JobCoordinator is present. That is correct on a single server. If you run
more than one, every one of them will run these jobs — add a coordinator.
```

That line is deliberate. The failure it describes is otherwise completely
silent: you find out from duplicated data, which is the worst place to learn
it.

### What happens when a job misbehaves

| | |
|---|---|
| It throws | Logged and counted; retried at its next firing. One broken job never stops the others. |
| It overruns its next firing | Skipped by default. Piling a second copy onto a job that has grown slow is how a slow job becomes an outage. |
| The clocks go back | A daily job runs once, not twice. Forward, a job in the missing hour runs once, late, rather than not at all. |

### Checkpoint

```bash
swift run App &
curl -sf --retry 30 --retry-connrefused --retry-delay 1 localhost:8080/actuator/health
# the startup log names the scheduler's mode and job count
kill %1
```

## Stage 3.8 — A browser remembers

Everything so far is either a bearer-token API or a socket. A browser has
neither in hand when it first arrives; it has a cookie. Sessions are the
state that belongs to *that browser* — where it left off, a notice for the
next page, and later, once it has signed in, who it is.

```swift
@Controller("/visits")
struct VisitsController {
    struct LastVisit: Codable, ResponseEncodable { let slug: String? }

    @GetRoute("/last")
    func last(_ context: RequestContext) throws -> LastVisit {
        LastVisit(slug: try context.requireSession().get("last-room", as: String.self))
    }

    @PostRoute("/:slug")
    func visit(_ context: RequestContext, slug: String) throws -> LastVisit {
        try context.requireSession().set("last-room", slug)
        return LastVisit(slug: slug)
    }

    @DeleteRoute("/")
    func forget(_ context: RequestContext) throws -> Response {
        try context.requireSession().destroy()
        return .status(.noContent)
    }
}
```

`AlulaSessionsModule` goes in `dependencies`, and that is the wiring: a
`Sessions` middleware in the default lane loads the session the cookie
names, hands it to the handler as `context.session`, and persists whatever
the handler did after it returns. `requireSession()` rather than unwrapping,
because the failure names the module to list.

Three things to notice, all visible with `curl -v`:

- **`GET /visits/last` on a fresh browser sets no cookie and stores
  nothing.** A session exists only once something is written, so crawlers
  and health checks cannot fill the store.
- **`POST /visits/lobby` answers with `Set-Cookie: session=…; HttpOnly;
  SameSite=Lax`**, and the next request carrying it reads `lobby` back.
  `Secure` is on by default — the cookie is a bearer credential — and off in
  `alula-dev.yaml` only, because this demo serves plain HTTP.
- **`DELETE /visits/` expires the cookie and deletes the record.**

The store is a seam. It is in-memory here, which is right for one process,
and `AlulaSessionsValkeyModule` from alula-data makes it shared across
replicas without touching a handler. A store that cannot answer is a 503
rather than an empty session — a browser silently signed out is the failure
nobody reports.

The test builds the real module with a recording store, so it proves the
cookie round-trips and not only that the handler reads what it wrote.

### Signing in with the cookie

The same session carries an identity. `SessionController` signs a browser
in — and is written so that it does not know *who* checks the password:

```swift
@Inject var provider: any SignInProvider

@GetRoute("/sign-in")
func begin(_ context: RequestContext) async throws -> Response {
    try await provider.beginSignIn(context, returnTo: context.request.queryParam("return-to"))
        .response()
}

@PostRoute("/", pipelines: [.default, "csrf"])       // the lane is explained below
func signIn(_ context: RequestContext) async throws -> Response {
    try await provider.signIn(context).response()
}

@GetRoute("/", pipelines: [.authenticated])
func whoAmI(_ context: RequestContext) throws -> WhoAmI {
    let principal = try context.requirePrincipal()          // from the cookie, not a header
    return WhoAmI(
        subject: principal.subject, email: principal.email, name: principal.name,
        roles: principal.roles.sorted(), csrfToken: try context.requireSession().csrfToken())
}
```

The provider comes from a module. `Main.swift` lists
`AlulaPasswordSignInModule`, which checks passwords against a
`CredentialStore` — here `DemoAccountsModule`'s in-memory one, seeded with
`ada@example.com` / `correct horse`. A real application implements that
protocol over its own users table: two methods, find an account by what the
user typed and save a stronger hash. The authenticator behind it does the
parts that are easy to get wrong — throttling before hashing, the same work
for an account that does not exist, one answer for every wrong guess.

`begin` answers with the form to draw — two fields, with the `autocomplete`
tokens password managers look for. **Switching to Keycloak, Auth0 or any
OpenID Connect provider is one line**: list `AlulaOIDCSignInModule` instead
and add a `security.oidc` block. `begin` then answers with a redirect to
the provider's own page, and the `GET /session/callback` route already in
the controller finishes the sign-in. Nothing else here changes, and
`principal.email` means the same thing either way — every provider emits
the same standard claims.

From then on `Authentication` finds the principal in the session on every
request that carries the cookie, and `requirePrincipal()`, `roles:` and the
`.authenticated` lane behave exactly as they do for a bearer token. Nothing
orders the two middlewares by hand: `AlulaSecurityModule` is handed the
session runtime in composition and runs `Sessions` ahead of
`Authentication` in every lane it declares. Signing in regenerates the
session id, so an id handed out before signing in is never the one signed
in.

### Guarding both ends

A cookie is ambient: a browser attaches it to a request a page never asked
the visitor to make. `CSRFProtection` is the middleware that refuses such a
request without a token only the session itself could have handed out —
`Session.csrfToken()`. Signing out needs it, and so does signing in:

```swift
@GetRoute("/csrf")                                   // anonymous: mints the token
func csrf(_ context: RequestContext) throws -> CSRFToken {
    CSRFToken(csrfToken: try context.requireSession().csrfToken())
}

@DeleteRoute("/", pipelines: [.default, "csrf"])
func signOut(_ context: RequestContext) async throws -> Response {
    try await provider.signOut(context).response()
}
```

Sign-in is the one people leave open, and here it would be forgeable. The
password provider also accepts `application/x-www-form-urlencoded`, which a
plain HTML form on any site can submit with no preflight, and
`SameSite=Lax` limits which cookies that POST *sends*, not which its
response *sets*. Unguarded, a hostile page could sign a visitor into the
attacker's account — "login CSRF". So an anonymous browser first calls
`GET /session/csrf`, which sets a cookie (minting a token is a session
write, the one cost of guarding a login) and answers with the token. The
token survives signing in, because `signIn` regenerates the id and keeps
the values, so the same one works for signing out later; `whoAmI` repeats
it for a client that has lost track.

`"csrf"` is a lane `AppModule` fills with `CSRFProtection()`, appended to
`.default` rather than folded into it — every other route in this app gets
a session too, since `Sessions` sits unconditionally in `.default`, but
none of the bearer-token ones has a *cookie* carrying real authority for
CSRF to protect, and folding the check into `.default` would ask all of
them for a token they have no page to have read one from.

Every response also carries `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY` and a strict `Referrer-Policy` without anything
here asking for them — `AlulaWebModule` applies them after every lane.
HSTS and a Content-Security-Policy are one `web.security-headers.*` key
each, once a deployment serves HTTPS and knows what its pages load.

### Checkpoint

```
$ curl -si -X POST localhost:8080/visits/lobby | grep -i set-cookie
set-cookie: session=…; Path=/; Max-Age=1209600; HttpOnly; SameSite=Lax
$ curl -s localhost:8080/visits/last -H 'Cookie: session=…'
{"slug":"lobby"}
$ curl -s localhost:8080/session/sign-in
{"fields":[{"name":"identifier",…},{"name":"password",…}]}  # the form to draw
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/session \
       -H 'content-type: application/json' \
       -d '{"identifier":"ada@example.com","password":"correct horse"}'
403                                                        # no token: login CSRF refused
$ curl -si localhost:8080/session/csrf
set-cookie: session=…                                     # minting the token stores a session
{"csrfToken":"…"}
$ curl -si -X POST localhost:8080/session -H 'content-type: application/json' \
       -H 'Cookie: session=…' -H 'X-CSRF-Token: …' \
       -d '{"identifier":"ada@example.com","password":"correct horse"}' | grep -i set-cookie
set-cookie: session=…                                     # a new id: signing in regenerated it
$ curl -s localhost:8080/session -H 'Cookie: session=…'
{"email":"ada@example.com","name":"Ada Lovelace","roles":["admin","author"],…}
$ curl -si -X DELETE localhost:8080/session \
       -H 'Cookie: session=…' -H 'X-CSRF-Token: …' | grep -i set-cookie
set-cookie: session=…                                     # signOut regenerated the id too
$ curl -si localhost:8080/visits/last | grep -i x-frame-options
x-frame-options: DENY
```

## Stage 3.9 — Wiring it together

`AppModule` now names what the app is made of:

```swift
static var dependencies: [any AlulaModule.Type] {
    [
        PostgresDataModule<PrimaryDataSource>.self,
        AlulaPubSubModule.self,
        AlulaPresenceModule.self,
        AlulaCacheModule.self,
        AlulaSchedulerModule.self,
        AlulaSecurityModule.self,
        AlulaSessionsModule.self,
        AlulaRateLimitModule.self,
    ]
}
```

That last one comes with a decision the framework refuses to make for you.
`AppModule` puts a `RateLimiting` in the default lane, and its key closure
is required:

```swift
RateLimiting(store: limiter.store, quota: .perMinute(300)) { context in
    context.principal?.subject ?? context.clientAddress?.host ?? "unknown"
}
```

Signed-in callers get their own budget, so one noisy user cannot spend
everyone else's. Anonymous traffic falls back to `clientAddress` — the real
caller, not necessarily `Request.remoteAddress`: behind a reverse proxy the
raw TCP peer is the proxy, and `clientAddress` is what accounts for that,
resolved from `X-Forwarded-For` only when `web.trusted-proxies` names the
connection as one to believe. Nothing is trusted by default, so this demo,
with no proxy configured, sees its own loopback connection as the address
either way. A deployment behind a real proxy sets `web.trusted-proxies` in
its own environment's config, and nothing here changes.

It runs after `Authentication`, which is the only reason reading the
principal works. `AppModule` depends on `AlulaSecurityModule`, and lane
order follows the module graph, so security's middleware sorts ahead of
this. Reverse that dependency and the key would silently read `nil` on
every request and limit the entire world as one caller.

Both the store and the session store are per process here. The Valkey
modules in alula-data make each of them mean one thing across every
replica, which is a module in the list rather than a change to any of
this code.

One line each. The DAG orders them; you do not. `AlulaChannelsModule` is not
in that list because it is `DemoChannelsModule`'s dependency rather than this
module's — the module that provides the channels is the one that must be built
after Channels.

`main` lists what the application includes, and the generated composer builds
each of them in dependency order:

```swift
modules: [
    AlulaWebModule<AlulaTransport>.self,
    DemoAuthModule.self,
    DemoChannelsModule.self,
    AppModule.self,
    ActuatorModule.self,
],
composedBy: alulaComposeModules
```

One bridge is needed, and it is worth understanding rather than copying:

```swift
extension Principal: @retroactive ChannelPrincipal {}
```

Alula Security's `Principal` and Alula Channels' `ChannelPrincipal` are
deliberately unrelated — Channels has no dependency on Security, so the
WebSocket layer works with any notion of identity, or none. They meet in
**your** code. The conformance is empty because `Principal` already has
everything the protocol asks for.

### Checkpoint

```bash
swift run App &
curl -sf --retry 30 --retry-connrefused --retry-delay 1 localhost:8080/actuator/health

TOKEN=demo:ada:moderator
curl -XPOST localhost:8080/rooms -H 'content-type: application/json' \
     -d '{"slug":"general","name":"General","greeting":"hello"}'
curl localhost:8080/rooms/general/who        # → [] — nobody connected yet
curl -XPOST localhost:8080/messages/redact -H 'content-type: application/json' \
     -d '{"sender":"ada","roomSlug":"general"}'          # → 401, no token
curl -XPOST localhost:8080/messages/redact \
     -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"sender":"ada","roomSlug":"general"}'          # → 200
kill %1
```

For the WebSocket half, connect to
`ws://localhost:8080/socket?token=demo:ada`, join `room:general`, and push a
`new_msg`. Two browser tabs will see each other's messages and each other's
presence.

### Checkpoint

```bash
swift test        # 36 tests, no database and no network required
```

That suite runs the real Channels router, the real PubSub fan-out, and the
real Presence CRDT against an in-memory store — including tests asserting
that a message is persisted before it is broadcast, and that a failed write
broadcasts nothing.

**You have now built [`templates/demo`](templates/demo).**

---

# Where to go next

- **Swap the demo validator** for real OIDC: delete
  `Sources/App/Security/DemoTokenValidator.swift` and set `security.oidc.*`.
- **Add a second node.** Presence and PubSub are already cluster-correct; a
  distributed PubSub adapter is a module.
- **Move the cache to Valkey**: add the `Valkey` trait and swap the module.
- **Read the Hangar tour** in
  [`ChatRepository.swift`](templates/demo/Sources/App/Repos/ChatRepository.swift)
  — three-table joins, a table joined to itself, `DISTINCT ON`, set-based
  writes, upserts, row locks under a serializable transaction with retry,
  `Multi`, and streaming.

# Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Build asks you to trust a plugin | Expected on a first build: the registration and migrate plugins are SwiftPM build plugins. Approve them. |
| Bootstrap fails naming `datasource.primary.url` | `alula.yaml` missing or mistyped, or you are not running from the project directory. |
| Bootstrap fails dialing the pool | Postgres container not running, or wrong port/password. |
| Build error naming a `@ConfigValue` key | The plugin checks keys without defaults against `alula.yaml` at build time. Add the key, or give it a `default:`. |
| `migrate` cannot connect | `ALULA_DATABASE_URL` is unset in this shell. The CLI does not read `alula.yaml`. |
| `checksum mismatch` from migrate | You edited a migration that already ran. Write a new one, or `migrate repair` if the edit was cosmetic. |
| `poolExhausted` under load | More concurrent operations than the pool has connections, for longer than `checkout_timeout_ms`. Raise `pool_size`, shorten the bracket, or map the error to a 503 with an `ErrorMapper`. |
| A streamed export starves other requests | `repo.stream` borrows a connection for its whole closure, and a slow client sets that length. Page the query, or give exports their own small pool. |
| A join is rejected with `unauthenticated` | The socket connected without a `?token=`, or the validator rejected it. |
| `swift run` says there are multiple executables | Name one: `swift run App`, `swift run migrate`. |
| Port already bound | `ALULA_SERVER_PORT=9090 swift run App`. |

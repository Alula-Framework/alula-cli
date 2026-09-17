# Building a Flight application

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
- Docker, from Part 2 onward, for Postgres
- No prior Flight knowledge; some Swift concurrency will help in Part 3

## The shape of a Flight application

Three ideas carry most of the framework, and they are worth having in mind
before any code:

**Registration happens at build time.** A build plugin scans your target for
`@Controller`, `@Service`, `@Repository`, and `@Component`, and generates the
registration code. Adding a controller does not mean editing a list. A
misspelled configuration key is a compile error, not a 3am page.

**Composition is by module, and modules form a DAG.** You choose behaviour by
adding a module to `bootstrap`, and the framework orders them. Choosing an
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

If you have the CLI, `flight new MyService` writes everything in this part for
you and you can skip to Stage 1.5's checkpoint. Doing it by hand once is worth
it — the rest of the tutorial assumes you know what each piece is for.

Create a directory and a `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    dependencies: [
        .package(url: "https://github.com/Flight-Framework/flight.git",
                 from: "0.18.0", traits: ["Web"])
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "FlightCore", package: "flight"),
                .product(name: "FlightWeb", package: "flight"),
                .product(name: "FlightTransport", package: "flight"),
                .product(name: "FlightActuator", package: "flight"),
            ],
            plugins: [
                .plugin(name: "FlightRegistrationPlugin", package: "flight")
            ]
        )
    ]
)
```

One package dependency gives you four products. `flight` is a single package
with many library products, so you take what you use — and `traits: ["Web"]`
says which of its optional layers you want. Nothing you do not name gets
resolved: the authentication stack and its JWT dependencies are simply absent
from this project.

**`FlightTransport` deserves a note.** Flight Web owns routing, middleware,
and the request/response model; it does not own a socket. `FlightTransport`
is the default transport, wrapping HummingbirdCore — a mature, versioned HTTP
implementation. Flight does not hand-roll HTTP parsing, and any conforming
transport is a peer of this one.

**The plugin is not optional decoration.** It generates `flightRegisterAll`
from what it finds in your sources, and checks your `@ConfigValue` keys
against `flight.yaml` at build time.

### Checkpoint

```bash
swift build
```

Downloads the framework and succeeds with no targets to compile yet.

## Stage 1.2 — Configuration

Create `flight.yaml` beside `Package.swift`:

```yaml
app:
  name: App

server:
  host: 127.0.0.1
  port: 8080

actuator:
  format: json
```

Flight Config layers sources: this file, then `FLIGHT_*` environment
variables over it, then anything a module contributes. The result is frozen
into an immutable `Configuration` at bootstrap. **Nothing re-reads this file
at runtime** — a configuration value cannot change under a running request,
which is why `Configuration` is safe to hold anywhere.

`FLIGHT_SERVER_PORT=9090 swift run App` overrides the port without editing
the file. The mapping is mechanical: dots become underscores, uppercased.

## Stage 1.3 — Bootstrap

Create `Sources/App/Main.swift`:

```swift
import FlightActuator
import FlightCore
import FlightTransport
import FlightWeb

struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [] }

    func configure(_ container: Container) throws {
        try flightRegisterAll(container)
    }
}

@main
struct Main {
    static func main() async {
        do {
            try await Flight.bootstrap(
                configuration: try Configuration.load(),
                modules: [
                    FlightWebModule<FlightTransport>.self,
                    AppModule.self,
                    ActuatorModule.self,
                ]
            )
        } catch {
            FileHandle.standardError.write(
                Data("App failed to start: \(String(reflecting: error))\n".utf8))
            exit(1)
        }
    }
}
```

`main` is `async`, not `async throws`, and that is worth a sentence. An error
that escapes `main` is reported by the Swift runtime as "Fatal error: Error
raised at top level", followed by a register dump and a backtrace. The two
startup failures you will actually hit — Postgres not running, port 8080
already bound — are not crashes and should not look like them.

`String(reflecting:)` rather than plain interpolation because PostgresNIO
redacts its `description` on purpose; the reflected form names the host, the
port and the errno. That is safe on this path specifically: bootstrap has no
user queries or bind values to leak, and the process is exiting anyway.

`flightRegisterAll` does not exist in any file you wrote — the plugin
generates it. It will be empty until Stage 1.4, and that is fine.

What `bootstrap` does, in order: load configuration, build the container,
resolve the module DAG, run every `configure` serially, **freeze** the
container, then start services. Registration and use are separate phases, so
nothing serves traffic against a half-registered container, and a missing
dependency fails at startup naming what was missing.

### Checkpoint

```bash
swift run App
```

Starts and logs its bound address. `curl localhost:8080/actuator/health`
returns JSON. Every route 404s, because you have not written one. Ctrl-C.

## Stage 1.4 — A route

Create `Sources/App/Controllers/HealthController.swift`:

```swift
import FlightCore
import FlightWeb

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
`flight.yaml`. Try misspelling it as `app.nmae` and rebuild: the build fails
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
        .product(name: "FlightCore", package: "flight"),
        .product(name: "FlightWeb", package: "flight"),
        .product(name: "FlightWebTesting", package: "flight"),
    ]
)
```

And `Tests/AppTests/HealthControllerTests.swift`:

```swift
import FlightCore
import FlightWeb
import FlightWebTesting
import Testing

@testable import App

@Suite("Health route")
struct HealthControllerTests {
    @Test("the index route answers with the configured application name")
    func index() async throws {
        let container = try TestContainer.build(
            configuration: Configuration(values: ["app.name": "TestApp"])
        ) {
            AppModule()
        }
        let client = try TestClient(container: container)

        let response = await client.get("/")

        #expect(response.status == .ok)
        #expect(response.bodyText == "TestApp is flying")
    }
}
```

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
docker run -d --name flight-postgres \
  -e POSTGRES_PASSWORD=flight -e POSTGRES_DB=app_dev \
  -p 55432:5432 postgres:16
```

Port 55432 rather than 5432, deliberately: a starter project should not fight
whatever is already on the default port.

Add to `flight.yaml`:

```yaml
datasource:
  primary:
    url: "postgres://postgres:flight@127.0.0.1:55432/app_dev?sslmode=disable"
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
    .package(url: "https://github.com/Flight-Framework/flight.git",
             from: "0.18.0", traits: ["Web"]),
    .package(url: "https://github.com/Flight-Framework/flight-data.git",
             from: "0.18.0", traits: ["Postgres"]),
],
```

**That `traits:` argument is doing real work.** `flight-data` carries the
Postgres driver, the Valkey driver, the in-memory cache, and the data
protocols. Without the `Postgres` trait, PostgresNIO is not merely unused —
it is never resolved, never fetched, and never appears in your
`Package.resolved`. Add `"Valkey"` alongside it when you want that adapter
too.

Traits are opt-in throughout: this project resolves 34 packages, and neither
`valkey-swift` nor `jwt-kit` is among them, because nothing asked for them.
That is also why Flight requires Swift 6.3 — SwiftPM 6.2 could not resolve an
opt-in trait through a versioned dependency.

Add `FlightDataPostgres` to the `App` target's dependencies, and two new
targets:

```swift
.target(
    name: "Migrations",
    dependencies: [.product(name: "FlightMigrate", package: "flight-data")],
    plugins: [.plugin(name: "FlightMigratePlugin", package: "flight-data")]
),
.executableTarget(
    name: "migrate",
    dependencies: [
        "Migrations",
        .product(name: "FlightMigrateCLI", package: "flight-data"),
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
flight migrate init
```

In a project with no migration targets it writes `Sources/migrate/Migrate.swift`,
creates `Sources/Migrations/` with a placeholder so the target has a module to
build, and inserts both targets plus the `flight-data` dependency into
`Package.swift`. In a project that already has them it says so and changes
nothing.

Every other migration command is the same tool you already have, reached
through `flight` instead of `swift run`:

| | |
| --- | --- |
| `flight migrate` | apply everything pending |
| `flight migrate status` | what is applied, what is not |
| `flight migrate status --json` | the same, machine-readable |
| `flight migrate create AddPosts` | write a new timestamped migration |
| `flight migrate rollback` | revert the last one |
| `flight migrate rollback --steps 3` | revert the last three |
| `flight migrate rollback --to 20260101000000` | revert down to a version |
| `flight migrate repair` | re-checksum a migration you edited |
| `flight migrate --dry-run` | print the SQL without running it |
| `flight migrate --help` | every option |

Arguments are passed straight through, so anything the underlying tool accepts
works here.

**Why it builds your project first.** Migrations are Swift types in your
package, found at build time. A globally installed binary cannot know what
`CreateUsers.up(_:)` does, so `flight migrate` builds and runs your project's
own migrate executable. The first run of a session pays for a build; the rest
are instant.

The connection URL comes from `--database-url`, then `$FLIGHT_DATABASE_URL`,
then `$DATABASE_URL` — never from `flight.yaml`, so a migration tool is always
explicit about which database it is about to alter.

This tutorial keeps using `swift run migrate` so it works with or without the
CLI installed. They are the same commands.

## Stage 2.3 — An entity

`Sources/App/Entities/User.swift`:

```swift
import FlightDataPostgres
import FlightWeb
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
FLIGHT_DATABASE_URL=postgres://postgres:flight@127.0.0.1:55432/app_dev \
  swift run migrate create CreateUsers
```

That writes a timestamped file into `Sources/Migrations`. Fill it in:

```swift
import FlightMigrate
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
export FLIGHT_DATABASE_URL=postgres://postgres:flight@127.0.0.1:55432/app_dev
swift run migrate status       # one pending
swift run migrate              # applies it — `apply` is the default subcommand
swift run migrate status       # one applied
swift run migrate rollback     # reverts it
swift run migrate              # and forward again
```

The subcommands are `apply` (the default, so bare `migrate` applies),
`status`, `rollback`, `create`, and `repair`. `migrate --help` lists every
option.

The CLI reads `FLIGHT_DATABASE_URL`, not `flight.yaml` — a migration tool
should be explicit about which database it is about to alter.

## Stage 2.5 — A repository, and the seam in front of it

Two files. First the seam, `Sources/App/Repos/UserRepositoryProtocol.swift`:

```swift
import FlightDataPostgres
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
import FlightDataPostgres
import Foundation

@Repository
struct UserRepository: UserRepositoryProtocol {
    // flight:hand-registered — PostgresDataModule registers the pool.
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
        return try await repo.insert(
            User(id: UUID(), name: name, email: email, createdAt: now, updatedAt: now))
    }
}
```

**Why the protocol?** A struct wrapping a live database scope cannot be
swapped out. A protocol can. That is the entire reason Stage 2.7's tests can
run the real controller, real routing, and real dependency injection with no
database in the loop. Depend on the protocol everywhere except at
registration.

**Why hold the pool rather than a connection?** Because the borrow is then
visible. `withRepo` leases for the length of its closure and returns the
connection when it ends, so a slow handler holds one only while it is actually
querying, and two statements share a connection exactly when you put them in
one bracket. A repository that held a connection for the whole request made
"how long is this borrowed for?" a question about a scope somewhere else.

Finally, tell the container about Postgres — in `Main.swift`:

```swift
static var dependencies: [any FlightModule.Type] {
    [PostgresDataModule<PrimaryDataSource>.self]
}
```

## Stage 2.6 — Routes

`Sources/App/Controllers/UserController.swift`:

```swift
@Controller
struct UserController {

    /// A controller is constructed per request from the component graph, so
    /// what it needs is a property the build wires — visible in the type,
    /// checked when the application is composed, and with no per-request
    /// lookup that could fail.
    @Inject var users: any UserRepositoryProtocol

    @GetRoute("/users")
    func list(_ context: RequestContext) async throws -> [User] {
        try await users.all()
    }

    @GetRoute("/users/:id")
    func get(_ context: RequestContext) async throws -> User {
        guard let id = context.pathParam("id").flatMap({ UUID(uuidString: $0) }) else {
            throw HTTPError(.badRequest, "user id must be a UUID")
        }
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

The controller depends on `(any UserRepositoryProtocol)`, so a test registers
a fake under that key and everything above it runs for real:

```swift
let container = try TestContainer.build {
    Components(UserController.self)
    Fake(users)
}
let client = try TestClient(container: container)

let response = await client.get("/users")
```

`Components` registers exactly the components under test, through the same
registration thunk the application uses — so the controller reaches the
container the way it does in production. `TestClient` dispatches **in
process**: routing, middleware, dependency injection, request decoding, and
JSON encoding all run, but there is no socket and no port to collide with.
These tests are fast because the network is absent, not because the framework
is stubbed.

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
#expect(response.status == .badRequest)
#expect(users.stored.isEmpty, "validation must run before the write")
```

### Three sizes of test

`Components` is the middle one, and the one you will reach for most:

| | What runs | Use it when |
|---|---|---|
| Call the handler | One method | The logic is the point and routing is not |
| `Components` | The real controller, routing, middleware, DI | Most of the time |
| `AppModule` + `override` | Every module the application boots | Checking the wiring itself |

The third deserves a word, because it catches a class of bug the other two
cannot. Registering a fake *alongside* a real module fails — registration is
first-wins and reports the collision when the container freezes — so swapping
one seam in a fully booted application uses `override`:

```swift
let container = try TestContainer.build {
    AppModule()
} overriding: { container in
    container.override((any UserRepositoryProtocol).self, scope: .singleton) { _ in users }
}
```

Freezing a container is where lifetime mistakes surface: a singleton that
captured a request-scoped repository, or two modules both claiming a key.
Testing a single layer skips the freeze, so it skips those. The demo carries
a `BootstrapTests` suite that boots its real modules for exactly this reason.

The complete suite is in
[`templates/basics`](templates/basics/Tests/AppTests/UserControllerTests.swift).

### Checkpoint

```bash
swift test        # 8 tests pass, no database required
```

## Where the service layer goes

`Sources/App/Services/` is still empty, and `UserController` resolves the
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

Flight Security Core is a **resource server**. It validates tokens somebody
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

Signature verification delegates to JWTKit. Flight owns orchestration only.

For a tutorial that runs with no identity provider, the demo registers its
own validator instead —
[`DemoTokenValidator`](templates/demo/Sources/App/Security/DemoTokenValidator.swift),
which accepts `demo:ada:moderator` and does no cryptography at all. Register
it **before** `FlightSecurityModule` and the module finds one present and
stands down:

```swift
container.register((any TokenValidator).self, scope: .singleton) { _ in
    DemoTokenValidator()
}
```

That is the bring-your-own-auth seam, and the demo file exists to show it.
**Delete it in anything real** and configure `security.oidc.*`. Rolling your
own token format is exactly the mistake this layer is shaped to prevent; the
demo gets away with it only because its tokens grant access to a chat room on
your laptop.

Guarding a route is a line in the handler:

```swift
try context.requireRole("moderator")
```

401 with no principal, 403 with the wrong one. Listing `RequireAuthentication`
in `container.pipeline { }` instead protects *every* route — right for an
internal service, wrong for an app whose reads are public.

## Stage 3.3 — A channel

A `Channel` is per-topic server logic. Joining creates one instance per
(socket, topic), so one declaration serves every room. A module *holds* its
channels as a value:

```swift
struct AppModule: FlightModule {
    let channels: [ChannelRegistration]

    init(graph: FlightGraph, presence: any Presence) {
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
and hands them to `FlightChannelsModule`, which builds its router from them —
so a malformed or duplicate pattern fails at startup, and a package outside
your application can contribute channels without you listing them anywhere.

The socket itself is a route, so it is declared like one, in
[`SocketController.swift`](templates/demo/Sources/App/Controllers/SocketController.swift):

```swift
@Controller
struct SocketController {
    @Inject var validator: any TokenValidator

    @WebSocketRoute("/socket")
    func socket(_ context: RequestContext) async throws -> ChannelSocketHandler {
        var principal: (any ChannelPrincipal)?
        if let token = context.request.queryParam("token") {
            principal = try? await validator.validate(token)
        }
        return try ChannelSocketHandler(context: context, principal: principal)
    }
}
```

**Identity is established during the HTTP upgrade**, before the WebSocket
exists — while there is still an HTTP response to fail with. The token
arrives as a query parameter because browsers cannot set headers on a
WebSocket handshake. An anonymous socket is admitted deliberately, and every
`join` below then rejects it.

`container.registerChannelSocket("/socket")` does the same wiring in one
line, and is what a test harness or a quick spike wants. Prefer the declared
form in an application: a route registered from a module body is arbitrary
Swift, so nothing can enumerate it at build time — it does not appear in the
static route manifest, and the dependency it needs arrives through
`context.resolve` rather than through the type.

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

Clients get one `flight:presence_state` on join, then `flight:presence_diff`s.
Both reference clients maintain the list for you: `FlightPresenceClient` in
Swift, `@flight-framework/channels/presence` in JavaScript.

## Stage 3.6 — Caching the expensive reads

Two of the demo's queries are worth caching — a `GROUP BY … HAVING` over every
message, and a `DISTINCT ON` across every room. Both are expensive, both are
polled by dashboards, and both tolerate being a few seconds stale.

```swift
@Service(scope: .singleton)
struct RoomDigestService {
    @Inject var chat: ChatRepository

    @Cacheable(namespace: "room-digest", ttl: .seconds(30))
    func activity(minimumMessages: Int) async throws -> [RoomActivity] {
        try await chat.activity(minimumMessages: minimumMessages)
    }

    @CacheEvict(namespace: "room-digest", allEntries: true)
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

`FlightCacheModule` is in-memory by default. Swapping in Valkey is a module
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

Add `FlightSchedulerModule.self` to `AppModule.dependencies` and that is the
whole setup. Nothing registers `ChatJobs` by hand — the plugin found it, the
same way it found your controllers.

A `@Scheduler` type is an ordinary component. It injects with `@Inject`
like anything else, and its jobs are ordinary methods — so testing one needs
no scheduler, no clock and no database, exactly like testing a service:

```swift
private func jobs(rooms: [RoomActivity]) throws -> ChatJobs {
    let container = try TestContainer.build {
        Components(ChatJobs.self)
        FakeDigests(rooms: rooms)
    }
    return try container.resolve(ChatJobs.self)
}

@Test func summaryCountsBusyRooms() async throws {
    try await jobs(rooms: [...]).nightlySummary()
}
```

Resolved from a container rather than constructed directly, and that is not
incidental: a macro that generates an initializer replaces the memberwise one,
so `ChatJobs(digests:)` does not exist. Every component in this app is built
the same way for the same reason — see `ChatJobsTests`, which is the code
above in full.

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

Swap `FlightCacheModule` for the Valkey-backed one and `warmDigests` becomes
the wrong annotation, because a shared cache only needs warming once. Where
the state lives is what decides which kind a job is — that is a real design
question, not a detail.

### Running once when there really are several servers

`once` needs something for the servers to contend through. `AppModule`
registers one — it is in the demo already, because a job that is only safe on
one machine is not much of a demonstration:

```swift
container.register((any JobCoordinator).self, scope: .singleton) { c in
    PostgresJobCoordinator(dataSource: try c.resolve(PostgresDataSource.self))
}
```

It claims a lease row keyed on the job and the *firing instant*, so exactly
one server wins each firing — and two servers whose clocks differ by a second
still agree which firing they are contending for. On this single-process demo
it changes nothing observable, which is rather the point: the code you write
is the same either way.

Comment it out and the scheduler tells you at startup:

```
warning: 1 job(s) are set to run once per firing, and no distributed
JobCoordinator is registered. That is correct on a single server. If you run
more than one, every one of them will run these jobs — register a coordinator.
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

## Stage 3.8 — Wiring it together

`AppModule` now names what the app is made of:

```swift
static var dependencies: [any FlightModule.Type] {
    [
        PostgresDataModule<PrimaryDataSource>.self,
        FlightPubSubModule.self,
        FlightChannelsModule.self,
        FlightPresenceModule.self,
        FlightCacheModule.self,
        FlightSchedulerModule.self,
        FlightSecurityModule.self,
    ]
}
```

One line each. The DAG orders them; you do not.

One bridge is needed, and it is worth understanding rather than copying:

```swift
extension Principal: @retroactive ChannelPrincipal {}
```

Flight Security's `Principal` and Flight Channels' `ChannelPrincipal` are
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
swift test        # 31 tests, no database and no network required
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
| Bootstrap fails naming `datasource.primary.url` | `flight.yaml` missing or mistyped, or you are not running from the project directory. |
| Bootstrap fails dialing the pool | Postgres container not running, or wrong port/password. |
| Build error naming a `@ConfigValue` key | The plugin checks keys without defaults against `flight.yaml` at build time. Add the key, or give it a `default:`. |
| `migrate` cannot connect | `FLIGHT_DATABASE_URL` is unset in this shell. The CLI does not read `flight.yaml`. |
| `checksum mismatch` from migrate | You edited a migration that already ran. Write a new one, or `migrate repair` if the edit was cosmetic. |
| `poolExhausted` under load | More concurrent operations than the pool has connections, for longer than `checkout_timeout_ms`. Raise `pool_size`, shorten the bracket, or map the error to a 503 with an `ErrorMapper`. |
| A streamed export starves other requests | `repo.stream` borrows a connection for its whole closure, and a slow client sets that length. Page the query, or give exports their own small pool. |
| A join is rejected with `unauthenticated` | The socket connected without a `?token=`, or the validator rejected it. |
| `swift run` says there are multiple executables | Name one: `swift run App`, `swift run migrate`. |
| Port already bound | `FLIGHT_SERVER_PORT=9090 swift run App`. |

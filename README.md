# Alula CLI

The `alula` command, the starter templates it emits, and the tutorial that
builds them.

## Install

```bash
git clone https://github.com/Alula-Framework/alula-cli.git
cd alula-cli
swift build -c release
cp .build/release/alula ~/.local/bin/
```

Requires Swift 6.3 or later. The CLI itself depends only on
swift-argument-parser and builds anywhere Swift 6.3 does.

The projects it *emits* are a separate question: they depend on `alula`, so
building one on a Mac needs the **macOS 26 SDK (Xcode 26)**. That is a build
requirement, not a deployment one — what you build still runs on macOS 15. See
[alula's README](https://github.com/Alula-Framework/alula#requirements) for
why. On Linux, Swift 6.3 is the only requirement.

## Create a project

```bash
alula new MyService                  # skeleton
alula new MyService --tier basics    # with a database
alula new MyService --tier demo      # everything
```

The tier chooses the code; `--with` chooses the dependencies:

```bash
alula new MyService --tier basics --with postgres,valkey
```

`postgres`, `valkey` and `security` are the options, and each maps to a
package trait — anything not named is never resolved. The tier's defaults
cover the usual case, and a combination the tier's own code could not compile
is refused rather than emitted.

The templates are embedded in the binary, so a generated project is
byte-for-byte what CI built and tested — with the target renamed to yours.

## Develop

```sh
alula dev                         # build, run, and rebuild + restart on every change
alula routes                      # every route: method, path, lanes, handler
alula routes --json
alula generate controller Orders  # Sources/App/Controllers/OrdersController.swift + a test
```

`alula dev` restarts the app with SIGTERM, as an orchestrator would, so it
drains and shuts down in order. A failed build leaves the previous one
running.

## Ship

Every template has a `Dockerfile`: a release build with the static Swift
standard library on a small Ubuntu base, run as a non-root user with
`ALULA_ENV=prod`. Projects with migrations get the `migrate` tool in the same
image:

```sh
docker build -t app .
docker run --entrypoint ./migrate -e ALULA_DATABASE_URL=... app apply
docker run -p 8080:8080 -e ALULA_DATASOURCE_PRIMARY_URL=... app
```

## Run migrations

```bash
alula migrate                    # apply everything pending
alula migrate status             # what is applied, what is not
alula migrate status --json      # the same, machine-readable
alula migrate create AddPosts    # write a new timestamped migration
alula migrate rollback           # revert the last one
alula migrate rollback --steps 3
alula migrate rollback --to 20260101000000
alula migrate repair             # re-checksum an edited migration
alula migrate --dry-run          # print the SQL without running it
alula migrate --help             # the full option list
```

The connection URL comes from `--database-url`, then `$ALULA_DATABASE_URL`,
then `$DATABASE_URL`.

Every argument is passed through to the project's migrate executable, so the
whole command set is available and stays available — a flag added there works
here with nothing to keep in sync.

Migrations are Swift types in your package, discovered at build time, so
running them means building your project. A globally installed binary cannot
know what `CreateUsers.up(_:)` does; this builds and runs the project's own
tool for you.

A project without migration targets — anything started from `skeleton` — gets
them with:

```bash
alula migrate init
```

## Pick a starting point

| Template | For | Includes |
|---|---|---|
| [`skeleton`](templates/skeleton) | A new service | Configuration, DI, HTTP, health endpoints |
| [`basics`](templates/basics) | A service with a database | + entities, migrations, a repository, CRUD |
| [`demo`](templates/demo) | Reading, not starting from | + PubSub, Channels, Presence, caching, auth, the full query tour |

`alula new` emits one of these with your project's name substituted. You can
also copy a directory by hand — each is a working project with passing tests.

## Or follow the tutorial

[TUTORIAL.md](TUTORIAL.md) builds all three in order — Part 1 ends at
`skeleton`, Part 2 at `basics`, Part 3 at `demo`. Every stage ends with a
command and what you should see.

## Why the templates are nested

`skeleton`'s files are a subset of `basics`', and `basics`' a subset of
`demo`'s. That is checked in CI, and it is not decoration: it is what lets
each tutorial stage be a real diff between two working projects rather than
prose that slowly stops matching the code.

## Verifying

```bash
./CI/verify-templates.sh            # build and test all three tiers
./CI/verify-templates.sh basics     # or just one
./CI/verify-tutorial.sh             # every path, symbol and type the tutorial names
./CI/verify-checkpoints.sh          # run the tutorial's checkpoint commands for real
./CI/verify-generated-projects.sh   # build and test what `alula new` emits
./CI/verify-migrate.sh              # the migrate command surface, end to end
./CI/generate-embedded-templates.sh # re-embed after changing templates/
```

`alula new`'s output is verified separately from the templates because it is
a different artifact: the CLI renames the target and rewrites manifest
strings, imports, and paths, and any of that can be wrong in a way the
templates themselves would never reveal.

Templates ship URL dependencies, because that is what a downloaded project
must contain. `verify-templates.sh` copies each tier to a scratch directory
and rewrites those to local paths before building, so the tiers can be
checked against working copies of `alula` and `alula-data` — the templates
themselves are never modified.

CI runs all of them, and `alula` and `alula-data` call this workflow, so a
breaking change there fails on the pull request that caused it rather than in
someone's first ten minutes with a downloaded project.

## License

MIT. See [LICENSE](LICENSE).

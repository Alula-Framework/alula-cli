# Flight CLI

The `flight` command, the starter templates it emits, and the tutorial that
builds them.

## Install

```bash
git clone https://github.com/Flight-Framework/flight-cli.git
cd flight-cli
swift build -c release
cp .build/release/flight ~/.local/bin/
```

Requires Swift 6.3 or later.

## Create a project

```bash
flight new MyService                  # skeleton
flight new MyService --tier basics    # with a database
flight new MyService --tier demo      # everything
```

The tier chooses the code; `--with` chooses the dependencies:

```bash
flight new MyService --tier basics --with postgres,valkey
```

`postgres`, `valkey` and `security` are the options, and each maps to a
package trait — anything not named is never resolved. The tier's defaults
cover the usual case, and a combination the tier's own code could not compile
is refused rather than emitted.

The templates are embedded in the binary, so a generated project is
byte-for-byte what CI built and tested — with the target renamed to yours.

## Run migrations

```bash
flight migrate                    # apply everything pending
flight migrate status             # what is applied, what is not
flight migrate status --json      # the same, machine-readable
flight migrate create AddPosts    # write a new timestamped migration
flight migrate rollback           # revert the last one
flight migrate rollback --steps 3
flight migrate rollback --to 20260101000000
flight migrate repair             # re-checksum an edited migration
flight migrate --dry-run          # print the SQL without running it
flight migrate --help             # the full option list
```

The connection URL comes from `--database-url`, then `$FLIGHT_DATABASE_URL`,
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
flight migrate init
```

## Pick a starting point

| Template | For | Includes |
|---|---|---|
| [`skeleton`](templates/skeleton) | A new service | Configuration, DI, HTTP, health endpoints |
| [`basics`](templates/basics) | A service with a database | + entities, migrations, a repository, CRUD |
| [`demo`](templates/demo) | Reading, not starting from | + PubSub, Channels, Presence, caching, auth, the full query tour |

`flight new` emits one of these with your project's name substituted. You can
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
./CI/verify-generated-projects.sh   # build and test what `flight new` emits
./CI/verify-migrate.sh              # the migrate command surface, end to end
./CI/generate-embedded-templates.sh # re-embed after changing templates/
```

`flight new`'s output is verified separately from the templates because it is
a different artifact: the CLI renames the target and rewrites manifest
strings, imports, and paths, and any of that can be wrong in a way the
templates themselves would never reveal.

Templates ship URL dependencies, because that is what a downloaded project
must contain. `verify-templates.sh` copies each tier to a scratch directory
and rewrites those to local paths before building, so the tiers can be
checked against working copies of `flight` and `flight-data` — the templates
themselves are never modified.

CI runs all of them, and `flight` and `flight-data` call this workflow, so a
breaking change there fails on the pull request that caused it rather than in
someone's first ten minutes with a downloaded project.

## License

MIT. See [LICENSE](LICENSE).

#!/usr/bin/env bash
#
# Exercises `alula migrate` end to end against a real database.
#
# Generates a skeleton project (which has no migration targets), adds them with
# `alula migrate init`, writes a migration, applies it, checks the table
# exists, rolls it back, and checks it is gone. Every command is the CLI's,
# not the underlying tool's, so the delegation is what is under test.
#
# Needs ALULA_TEST_DATABASE_URL. Skips, loudly, without it.
#
set -euo pipefail
cd "$(dirname "$0")/.."
here="$(pwd)"

if [ -z "${ALULA_TEST_DATABASE_URL:-}" ]; then
  echo "::warning::ALULA_TEST_DATABASE_URL is not set — skipping the migrate check"
  exit 0
fi

swift build --product alula >/dev/null
cli="$(swift build --product alula --show-bin-path)/alula"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

echo "── generating a project with no migration targets"
"$cli" new MigrationCheck --tier skeleton --path "$scratch/p" >/dev/null

echo "── alula migrate before init should explain itself"
if (cd "$scratch/p" && "$cli" migrate status >/dev/null 2>&1); then
  echo "::error::migrate succeeded in a project with no migrate target"
  exit 1
fi

echo "── alula migrate init"
(cd "$scratch/p" && "$cli" migrate init >/dev/null)

echo "── alula migrate create"
(cd "$scratch/p" && "$cli" migrate create CreateWidgets >/dev/null)
migration=$(ls "$scratch/p"/Sources/Migrations/*_CreateWidgets.swift)
python3 - "$migration" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
t = t.replace("    func up(_ schema: SchemaBuilder) {\n",
              "    func up(_ schema: SchemaBuilder) {\n"
              '        schema.createTable("widgets") { t in\n'
              '            t.uuid("id").primaryKey().default(.generatedUUID)\n'
              "        }\n")
t = t.replace("    func down(_ schema: SchemaBuilder) {\n",
              '    func down(_ schema: SchemaBuilder) {\n        schema.dropTable("widgets")\n')
p.write_text(t)
PY

export ALULA_DATABASE_URL="$ALULA_TEST_DATABASE_URL"
cd "$scratch/p"

echo "── alula migrate (apply)"
"$cli" migrate >/dev/null

echo "── alula migrate status"
"$cli" migrate status 2>/dev/null | grep -q "CreateWidgets" || {
  echo "::error::status does not list the applied migration"; exit 1; }

echo "── alula migrate rollback"
"$cli" migrate rollback >/dev/null
"$cli" migrate status 2>/dev/null | grep -q "No applied migrations" || {
  echo "::error::rollback did not revert the migration"; exit 1; }


echo "── every migrate subcommand the tutorial names really exists"
# This is the check that was missing: TUTORIAL.md told readers to run
# `migrate up` and `migrate down`, neither of which is a subcommand. Paths and
# symbols were verified; the commands were not, so two wrong ones shipped.
#
# The real binary is the source of truth — its help output, not a list kept
# here that could drift from it.
help_text="$("$cli" migrate --help 2>&1 || true)"
real=$(cd "$scratch/p" && swift run migrate --help 2>/dev/null \
       | sed -n '/SUBCOMMANDS:/,$p' | awk 'NR>1 && $1 ~ /^[a-z]+$/ {print $1}')
[ -z "$real" ] && { echo "::error::could not read the migrate subcommand list"; exit 1; }

used=$(grep -oE '(alula|swift run) migrate [a-z]+' "$here/TUTORIAL.md" \
       | awk '{print $NF}' | sort -u)
bad=0
for cmd in $used; do
  # `init` is the CLI's own, handled before delegation.
  [ "$cmd" = "init" ] && continue
  if ! echo "$real" | grep -qx "$cmd"; then
    echo "::error::TUTORIAL.md tells readers to run 'migrate $cmd', which is not a subcommand"
    bad=1
  fi
done
[ $bad -eq 0 ] && echo "  ✔ $(echo "$used" | wc -w) subcommand(s) named in the tutorial all exist"
[ $bad -eq 1 ] && exit 1

echo "✔ create, init, apply, status and rollback all work through the CLI"

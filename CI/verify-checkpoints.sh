#!/usr/bin/env bash
#
# Runs the tutorial's checkpoints for real.
#
# Each Part of TUTORIAL.md ends its stages with a "### Checkpoint" — a command
# and what you should see. Those are the tutorial's strongest feature and were
# its least verified part: verify-tutorial.sh checks that paths exist and
# symbols resolve, which is why `swift run migrate up` and `migrate down` sat
# in a checkpoint for weeks despite neither being a subcommand.
#
# This extracts every checkpoint block, runs it in the tier that Part builds,
# and fails if any command exits non-zero.
#
# What it does NOT check: the `# → …` comments. A curl that returns 404 still
# exits 0, so the commands are proven to *run*, not to produce what the
# tutorial claims. Asserting on output would mean parsing prose; the tests in
# each template cover the behaviour instead.
#
# Some checkpoints are interactive by design — Stage 1.3's is `swift run App`,
# which serves until you press Ctrl-C. Those cannot "finish", so they run under
# a timeout and a block still running when it expires counts as a pass: a
# server that is up after the deadline is a server that started.
#
# That used to apply to *every* checkpoint, which meant nine of the ten could
# hang forever and be reported green — `swift test` wedged, a migration
# blocked on a lock, a curl waiting on a server that never bound. Only a block
# that says it serves until interrupted gets that treatment now; for the rest,
# a timeout is a failure. The marker is the `Ctrl-C` the checkpoint already
# tells the reader about, which is why it lives in the block rather than in a
# list maintained over here.
#
# Needs ALULA_TEST_DATABASE_URL for Part 2 onward. Skips those, loudly,
# without it.
#
set -uo pipefail
cd "$(dirname "$0")/.."
here="$(pwd)"

swift build --product alula >/dev/null || exit 1
cli="$(swift build --product alula --show-bin-path)/alula"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Part -> tier. Part 1 builds the skeleton, Part 2 the basics, Part 3 the demo.
tier_for() {
  case "$1" in 1) echo skeleton ;; 2) echo basics ;; *) echo demo ;; esac
}

# Split TUTORIAL.md into checkpoint blocks tagged with their Part.
python3 - "$here/TUTORIAL.md" "$scratch" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
part, n = 0, 0
lines, block, in_block, seen_checkpoint = text.splitlines(), [], False, False
for line in lines:
    m = re.match(r"^# Part (\d+)", line)
    if m:
        part = int(m.group(1))
    if line.startswith("### Checkpoint"):
        seen_checkpoint = True
        continue
    if seen_checkpoint and line.startswith("```bash"):
        in_block, block = True, []
        continue
    if in_block and line.startswith("```"):
        n += 1
        (out / f"cp{n:02d}.part{part}.sh").write_text("\n".join(block) + "\n")
        in_block, seen_checkpoint = False, False
        continue
    if in_block:
        block.append(line)
print(n)
PY

total=0; failed=0; skipped=0
# An optional filter, because a full pass generates and builds a project per
# checkpoint and takes minutes:  ./CI/verify-checkpoints.sh cp05
filter="${1:-}"

for f in "$scratch"/cp*.sh; do
  [ -e "$f" ] || continue
  if [ -n "$filter" ] && [[ "$(basename "$f")" != *"$filter"* ]]; then continue; fi
  total=$((total + 1))
  name=$(basename "$f")
  part=$(echo "$name" | sed -E 's/.*\.part([0-9]+)\.sh/\1/')
  tier=$(tier_for "$part")

  if [ "$part" != "1" ] && [ -z "${ALULA_TEST_DATABASE_URL:-}" ]; then
    echo "  ~ $name (Part $part) — skipped, no ALULA_TEST_DATABASE_URL"
    skipped=$((skipped + 1))
    continue
  fi

  # A fresh project per checkpoint: they are meant to be run in order from a
  # clean start, and sharing one would let an earlier failure hide a later.
  #
  # Fresh *sources*, that is. The build directory is carried from one
  # checkpoint of a tier to the next, at the same path, because compiling
  # alula, alula-data, Hangar, NIO and PostgresNIO again for every checkpoint
  # was most of this job's 37 minutes, and none of it was what a checkpoint
  # checks. The path must stay the same: SwiftPM's products record absolute
  # paths, and a cache moved elsewhere rebuilds from scratch. Everything else
  # in the directory — sources, alula.yaml, anything a previous checkpoint
  # wrote — is deleted and generated again.
  work="$scratch/tier-$tier"
  cache="$scratch/build-cache-$tier"
  [ -d "$work/.build" ] && mv "$work/.build" "$cache"
  rm -rf "$work"
  "$cli" new App --tier "$tier" --path "$work" >/dev/null 2>&1
  [ -d "$cache" ] && mv "$cache" "$work/.build"

  # The tutorial hardcodes a local database URL; CI's is elsewhere. Both of
  # these are needed, because the two halves read different sources:
  #
  #   the migrate CLI  ->  $ALULA_DATABASE_URL   (it does not read alula.yaml)
  #   the application  ->  alula.yaml            (it does not read that variable)
  #
  # Patching only the first is what made cp06 and cp08 fail: the app kept
  # dialling 127.0.0.1:55432, died on connection refused, and the curls in
  # those checkpoints were racing a socket that existed for a few
  # milliseconds between "transport listening" and the pool giving up.
  if [ -n "${ALULA_TEST_DATABASE_URL:-}" ]; then
    sed -i "s|^export ALULA_DATABASE_URL=.*|export ALULA_DATABASE_URL=$ALULA_TEST_DATABASE_URL|" "$f"
    export ALULA_DATABASE_URL="$ALULA_TEST_DATABASE_URL"
    sed -i "s|url: \"postgres://[^\"]*\"|url: \"$ALULA_TEST_DATABASE_URL\"|" "$work/alula.yaml"
  fi

  # `set -m` because checkpoints background a server and then `kill %1`, which
  # needs job control that non-interactive shells leave off. The `-e` must be
  # on the inner `bash` running the block, not on the wrapper: a `set -e` in
  # the wrapper does not reach a child shell, so a command failing mid-block
  # would be ignored and the block's status taken from its last line.
  #
  # The build inside a fresh project dominates the budget, so warm it first
  # and time only the checkpoint itself.
  (cd "$work" && swift build) >"$scratch/$name.build.log" 2>&1

  # `setsid` puts the block in its own process group so everything it starts
  # can be killed as a unit below. Without that, a checkpoint that fails
  # before its `kill %1` leaves the server running — and because the process
  # shows up in `ps` as a *relative* path (`.build/.../App`), a `pkill -f`
  # on the work directory never matches it. One leaked server holds port 8080
  # and every later checkpoint dies with "Address already in use", which
  # reads as a cascade of unrelated failures.
  setsid bash -c "cd '$work' && set -em && bash -e '$f'" \
    >"$scratch/$name.log" 2>&1 &
  block=$!

  status=0
  waited=0
  # Longer than the tutorial's curl retry budget: a block's `swift run`
  # recompiles what the checkpoint changed, which took over 30s on a CI
  # runner and made cp08/cp09 fail with curl's "could not connect" (7).
  limit="${CHECKPOINT_TIMEOUT:-240}"
  # A block that serves until interrupted passes by still running at the
  # deadline, so waiting the full budget cost four minutes a run for nothing.
  # Its build is warm and its `swift run` recompiles one change, which is
  # well inside 90s even on a slow runner — and short of that it would pass
  # while still compiling, proving less than it claims.
  if grep -qiE 'ctrl-c|until you (press|interrupt)' "$f"; then
    limit="${CHECKPOINT_SERVE_TIMEOUT:-90}"
  fi
  while kill -0 "$block" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$block" 2>/dev/null; then
    # Still serving at the deadline: the pass condition for the interactive
    # checkpoints. SIGINT first, as Ctrl-C would.
    status=124
    pkill -INT -s "$block" 2>/dev/null || true
    sleep 2
  else
    wait "$block"
    status=$?
  fi

  # A checkpoint may only pass on a timeout if it says it is one that never
  # finishes. Everything else finishing is the thing being tested.
  if grep -qiE 'ctrl-c|until you (press|interrupt)' "$f"; then
    interactive=1
  else
    interactive=0
  fi

  case $status in
    0)   echo "  ✔ $name (Part $part, $tier)" ;;
    124|130)
         if [ "$interactive" = 1 ]; then
           # Still serving at the deadline, which is this checkpoint's whole
           # claim.
           echo "  ✔ $name (Part $part, $tier) — still running at the deadline"
         else
           echo "  ✘ $name (Part $part, $tier) — still running after ${limit}s, and this one is expected to finish"
           tail -8 "$scratch/$name.log" | sed 's/^/      /'
           failed=$((failed + 1))
         fi ;;
    *)   echo "  ✘ $name (Part $part, $tier) — exited $status"
         tail -8 "$scratch/$name.log" | sed 's/^/      /'
         failed=$((failed + 1)) ;;
  esac

  # Nothing from one checkpoint may outlive it into the next — see the setsid
  # note above for why matching on the work directory does not work either.
  # By session, not process group. `set -m` gives every job in the block
  # its own group, so a group kill reached the block's shell and missed the
  # server it ran: that server kept port 8080, and later checkpoints' curls
  # exited 0 against it. `setsid` made one session for all of them, and job
  # control does not leave it.
  pkill -TERM -s "$block" 2>/dev/null || true
  sleep 1
  pkill -KILL -s "$block" 2>/dev/null || true
  sleep 1
  if survivors=$(pgrep -a -s "$block"); then
    echo "  ✘ $name left processes running, which would answer the next checkpoint's requests:"
    echo "$survivors" | sed 's/^/      /'
    failed=$((failed + 1))
  fi
done

echo "  ── $total checkpoint(s): $((total - failed - skipped)) passed, $failed failed, $skipped skipped"
[ $failed -eq 0 ]

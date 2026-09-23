#!/usr/bin/env bash
#
# Builds and tests every template tier. This is the anti-drift mechanism: a
# breaking change in alula or alula-data fails here, not in a new user's
# first ten minutes.
#
# Templates ship URL dependencies, because that is what a downloaded project
# must contain. To verify them against working-copy code — and, before v0.1.0
# is tagged, to verify them at all — each tier is copied to a scratch
# directory and its URL dependencies are rewritten to local paths. The copy is
# what gets built; the template is never modified.
#
#   ./CI/verify-templates.sh                 # against sibling checkouts
#   ALULA_LOCAL=0 ./CI/verify-templates.sh  # against the published tags
#
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
alula_root="$(cd "$here/.." && pwd)"
use_local="${ALULA_LOCAL:-1}"
failed=0
scratch="$(mktemp -d)"
# Kept on failure so the `full log:` line points at something that exists.
# A function rather than an inline test: under `set -e` a trap whose last
# command is a failing `[` can carry that status into the script's exit.
cleanup() {
  if [ "$failed" -eq 0 ]; then rm -rf "$scratch"; fi
}
trap cleanup EXIT

tiers=("${@:-}")
if [ -z "${tiers[0]}" ]; then
  tiers=(skeleton basics demo)
fi

for tier in "${tiers[@]}"; do
  echo "──────── $tier ────────"
  work="$scratch/$tier"
  # Without the exclusions this copies the tier's build directory too, which
  # is 1.6–1.8 GB per template once anyone has built one in place — about 5 GB
  # of pointless I/O for a full run, and a slow check is a check people skip.
  # It also carried a stale `.build` into the scratch copy, which is its own
  # class of confusing failure.
  mkdir -p "$work"
  tar -C "$here/templates/$tier" --exclude=./.build --exclude=./.swiftpm -cf - . \
    | tar -C "$work" -xf -

  if [ "$use_local" = "1" ]; then
    # Point the copy's dependencies at the sibling checkouts. Shared with
    # verify-generated-projects.sh, which needs exactly the same rewrite.
    python3 "$here/CI/repoint-manifest.py" "$work/Package.swift" "$alula_root"
  fi

  # Full output to a log; the terminal gets the tail on success and the
  # *errors* on failure. Piping straight to `tail -3` showed the last three
  # lines of a failed build, which are the last three files that happened to
  # compile — so a break reported itself as "Compiling App Foo.swift" and the
  # reason had to be reproduced by hand. This script exists to catch breaks;
  # it should say what broke.
  log="$scratch/$tier.log"
  if (cd "$work" && swift build >"$log" 2>&1) && (cd "$work" && swift test >>"$log" 2>&1); then
    tail -3 "$log"
    echo "✔ $tier"
  else
    echo "✘ $tier FAILED"
    if grep -qE '^[^ ].*error:' "$log"; then
      # Swift reports the same diagnostic once per compilation job; deduped
      # in order so a single mistake reads as one line, not four.
      grep -E '^[^ ].*error:' "$log" | awk '!seen[$0]++' | head -20
    else
      tail -30 "$log"
    fi
    echo "  full log: $log"
    failed=1
  fi
done

exit $failed

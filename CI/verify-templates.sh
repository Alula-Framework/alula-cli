#!/usr/bin/env bash
#
# Builds and tests every template tier. This is the anti-drift mechanism: a
# breaking change in flight or flight-data fails here, not in a new user's
# first ten minutes.
#
# Templates ship URL dependencies, because that is what a downloaded project
# must contain. To verify them against working-copy code — and, before v0.1.0
# is tagged, to verify them at all — each tier is copied to a scratch
# directory and its URL dependencies are rewritten to local paths. The copy is
# what gets built; the template is never modified.
#
#   ./CI/verify-templates.sh                 # against sibling checkouts
#   FLIGHT_LOCAL=0 ./CI/verify-templates.sh  # against the published tags
#
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
flight_root="$(cd "$here/.." && pwd)"
use_local="${FLIGHT_LOCAL:-1}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

tiers=("${@:-}")
if [ -z "${tiers[0]}" ]; then
  tiers=(skeleton basics demo)
fi

failed=0
for tier in "${tiers[@]}"; do
  echo "──────── $tier ────────"
  work="$scratch/$tier"
  cp -R "$here/templates/$tier" "$work"

  if [ "$use_local" = "1" ]; then
    # Rewrite `.package(url: ".../flight.git", from: "x")` to a path, keeping
    # any `traits:` argument that followed the version.
    python3 - "$work/Package.swift" "$flight_root" <<'PY'
import re, sys, pathlib
manifest, root = pathlib.Path(sys.argv[1]), sys.argv[2]
text = manifest.read_text()

def to_path(match):
    repo, tail = match.group(1), match.group(2)
    traits = re.search(r'(traits:\s*\[[^\]]*\])', tail)
    args = f'path: "{root}/{repo}"'
    if traits:
        args += f", {traits.group(1)}"
    return f".package({args})"

text = re.sub(
    r'\.package\(\s*url:\s*"https://github\.com/Flight-Framework/([a-z-]+)\.git"\s*,([^)]*)\)',
    to_path, text)
manifest.write_text(text)
PY
  fi

  if (cd "$work" && swift build 2>&1 | tail -3) && (cd "$work" && swift test 2>&1 | tail -3); then
    echo "✔ $tier"
  else
    echo "✘ $tier FAILED"
    failed=1
  fi
done

exit $failed

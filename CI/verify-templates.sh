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
    # Point the copy's dependencies at the sibling checkouts. Shared with
    # verify-generated-projects.sh, which needs exactly the same rewrite.
    python3 "$here/CI/repoint-manifest.py" "$work/Package.swift" "$flight_root"
  fi

  if (cd "$work" && swift build 2>&1 | tail -3) && (cd "$work" && swift test 2>&1 | tail -3); then
    echo "✔ $tier"
  else
    echo "✘ $tier FAILED"
    failed=1
  fi
done

exit $failed

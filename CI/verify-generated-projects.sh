#!/usr/bin/env bash
#
# Builds and tests what `alula new` actually emits, for every tier.
#
# CI/verify-templates.sh checks the templates. This checks the *generated*
# project, which is a different artifact: the CLI renames the target, rewrites
# manifest strings, import statements, and paths, and any of that can be
# subtly wrong in a way the templates themselves would never reveal.
#
# Like verify-templates.sh, the generated project's URL dependencies are
# repointed at the checkouts sitting beside this repository, so CI verifies the
# commit under review rather than whatever tag is published. Without that, the
# `cli` job resolved released tags while its caller passed a `alula_ref` it
# then ignored — a breaking change in alula passed this job every time.
#
#   ./CI/verify-generated-projects.sh          # all tiers, against siblings
#   ./CI/verify-generated-projects.sh basics   # one
#   ALULA_LOCAL=0 ./CI/verify-generated-projects.sh   # against published tags
#
set -euo pipefail
cd "$(dirname "$0")/.."
here="$(pwd)"
alula_root="$(cd .. && pwd)"
use_local="${ALULA_LOCAL:-1}"

swift build --product alula >/dev/null
cli="$(swift build --product alula --show-bin-path)/alula"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

tiers=("$@")
[ ${#tiers[@]} -eq 0 ] && tiers=(skeleton basics demo)

status=0
for tier in "${tiers[@]}"; do
  echo "──────── $tier ────────"
  name="Generated${tier^}"
  "$cli" new "$name" --tier "$tier" --path "$scratch/$tier" >/dev/null

  if [ "$use_local" = "1" ]; then
    python3 "$here/CI/repoint-manifest.py" "$scratch/$tier/Package.swift" "$alula_root"
  fi

  # The generated project must contain no trace of the template's own target
  # name as an identifier — only in prose.
  if grep -rn '"App"\|import App\b\|Sources/App/\|AppTests' "$scratch/$tier" >/dev/null 2>&1; then
    echo "  ✘ generated project still refers to the template target 'App'"
    grep -rn '"App"\|import App\b\|Sources/App/\|AppTests' "$scratch/$tier" | head -3
    status=1
    continue
  fi

  if (cd "$scratch/$tier" && swift build 2>&1 | tail -2) \
     && (cd "$scratch/$tier" && swift test 2>&1 | tail -2); then
    echo "  ✔ $tier builds and tests as $name"
  else
    echo "  ✘ $tier FAILED"
    status=1
  fi
done

exit $status

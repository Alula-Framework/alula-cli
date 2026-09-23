#!/usr/bin/env python3
"""Rewrite a manifest's Alula-Framework URL dependencies to local checkouts.

Templates and generated projects ship URL dependencies, because that is what a
downloaded project must contain. Verifying them against working-copy code —
and, in CI, against the commit under review rather than whatever tag happens to
be published — means pointing those dependencies at the checkouts beside this
one.

    repoint-manifest.py <Package.swift> <root>

`root` holds the sibling checkouts, so `alula` resolves to `<root>/alula`.

A dependency whose target directory is missing is a hard error. Leaving the URL
in place would be worse than failing: the job would resolve the published tag,
build it happily, and report that it had verified the change under review. That
is the failure this script exists to prevent, so it must not be the failure
mode when something is set up wrong.
"""
import re
import sys
import pathlib

# Directories that are not `<root>/<repo>`, because the workspace nests them.
NESTED = {"hangar": "Hangar/hangar", "swift-changeset": "Data/swift-changeset"}

PATTERN = re.compile(
    r'\.package\(\s*url:\s*"https://github\.com/Alula-Framework/([a-z-]+)\.git"\s*,([^)]*)\)'
)


def main() -> int:
    manifest, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    text = manifest.read_text()
    missing: list[str] = []
    rewritten: list[str] = []

    def to_path(match: re.Match) -> str:
        repo, tail = match.group(1), match.group(2)
        target = root / NESTED.get(repo, repo)
        if not target.is_dir():
            missing.append(f"{repo} -> {target}")
            return match.group(0)
        rewritten.append(repo)
        # Keep any `traits:` argument that followed the version.
        traits = re.search(r"(traits:\s*\[[^\]]*\])", tail)
        args = f'path: "{target}"'
        if traits:
            args += f", {traits.group(1)}"
        return f".package({args})"

    text = PATTERN.sub(to_path, text)

    if missing:
        print(f"✘ {manifest}: no checkout for:", file=sys.stderr)
        for entry in missing:
            print(f"    {entry}", file=sys.stderr)
        print(
            "  Check them out beside this repository, or set ALULA_LOCAL=0 to\n"
            "  verify against the published tags instead.",
            file=sys.stderr,
        )
        return 1

    manifest.write_text(text)
    print(f"  repointed to local checkouts: {', '.join(rewritten) or 'nothing to rewrite'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
#
# Checks that TUTORIAL.md does not lie.
#
# The previous tutorial in this ecosystem drifted until seven of the nine
# files it told you to create no longer existed. Nothing caught that, because
# prose does not compile. This does the two checks that would have:
#
#   1. every templates/… path it links to exists
#   2. every type and function it names in a code block exists in the tier
#      that stage claims to build
#
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

echo "── linked paths"
# Markdown links and inline references to templates/…
grep -oE 'templates/[A-Za-z0-9_/.-]+' TUTORIAL.md | sed 's/[.,)]*$//' | sort -u | while read -r path; do
  if [ ! -e "$path" ]; then
    echo "  ✘ MISSING  $path"
    exit 1
  fi
done || status=1
[ $status -eq 0 ] && echo "  ✔ all referenced paths exist"

echo "── declared symbols"
# Every `struct X`, `protocol X`, or `func x(` the tutorial shows should exist
# somewhere in the templates. A renamed API in the framework shows up here as
# a tutorial that still names the old one.
missing=0
python3 - <<'PY'
import re, pathlib, sys

tutorial = pathlib.Path("TUTORIAL.md").read_text()
# Skip `.build`: a locally-built template vendors every dependency's source
# there, so the haystack would include all of alula and alula-data and this
# check would pass on names no template mentions. CI checks out fresh and has
# no `.build`, so leaving it in makes the check weaker here than in CI — the
# worst direction for a check to differ.
sources = "\n".join(
    p.read_text()
    for p in pathlib.Path("templates").rglob("*.swift")
    if ".build" not in p.parts
)

# Only symbols the tutorial presents as ours, in swift code fences.
blocks = re.findall(r'```swift\n(.*?)```', tutorial, re.S)
symbols = set()
for block in blocks:
    symbols |= set(re.findall(r'\b(?:struct|protocol|final class|enum)\s+([A-Z][A-Za-z0-9_]*)', block))
    symbols |= set(re.findall(r'\bfunc\s+([a-z][A-Za-z0-9_]*)\s*\(', block))

# Names that belong to the framework or to Swift, not to the templates.
external = {
    "Main", "AppModule", "TestModule", "InMemoryUsers",
    "main", "configure", "validate", "up", "down",
}
missing = sorted(s for s in symbols - external if s not in sources)
for name in missing:
    print(f"  ✘ tutorial names '{name}', which no template defines")
sys.exit(1 if missing else 0)
PY
if [ $? -eq 0 ]; then echo "  ✔ every symbol shown is defined in a template"; else status=1; fi
echo "── constructed types"
# The check above only looks at what the tutorial *declares*. It never looked
# at what the tutorial *calls*, which is how a snippet registering
# `PostgresJobCoordinator(...)` shipped while no template could resolve that
# type: a reader copying it got "cannot find PostgresJobCoordinator in scope".
#
# Every framework type the tutorial constructs must appear somewhere in the
# templates — defined there, or used there, which means the package providing
# it is a real dependency of a real project.
python3 - <<'PYCHECK'
import re, pathlib, sys

tutorial = pathlib.Path("TUTORIAL.md").read_text()
def template_files(pattern):
    return [
        p for p in pathlib.Path("templates").rglob(pattern) if ".build" not in p.parts
    ]

# `.build` excluded — see the note in the previous check.
haystack = "\n".join(p.read_text() for p in template_files("*.swift"))
haystack += "\n" + "\n".join(p.read_text() for p in template_files("Package.swift"))

# Swift and Foundation types a reader already has.
stdlib = {
    "Data", "Date", "UUID", "String", "Int", "Double", "Bool", "URL", "Set",
    "Array", "Dictionary", "Duration", "Task", "Error", "Result", "Optional",
    "Logger", "Configuration", "DateComponents", "TimeZone", "Calendar",
    "JSONEncoder", "JSONDecoder", "ByteBuffer", "Character", "Issue",
}

used = set()
for block in re.findall(r'```swift\n(.*?)```', tutorial, re.S):
    for name in re.findall(r'(?<![@.\w])\b([A-Z][A-Za-z0-9_]*)\s*\(', block):
        used.add(name)

missing = sorted(n for n in used - stdlib if n not in haystack)
for name in missing:
    print(f"  ✘ tutorial constructs '{name}', which no template can resolve")
sys.exit(1 if missing else 0)
PYCHECK
if [ $? -eq 0 ]; then echo "  ✔ every constructed type is resolvable"; else status=1; fi


echo "── checkpoint commands"
# Each part must end at a tier, and say so.
for tier in skeleton basics demo; do
  if ! grep -q "You have now built \[\`templates/$tier\`\]" TUTORIAL.md; then
    echo "  ✘ no closing checkpoint for the $tier tier"
    status=1
  fi
done
[ $status -eq 0 ] && echo "  ✔ every part closes on a tier"

echo "── removed APIs"
# The checks above see what the tutorial *declares* and what it *constructs*.
# Neither can see a plain call to something that no longer exists:
# `container.register(…)` declares nothing, and its receiver is lowercase, so
# the constructed-types regex — which looks for `Uppercase(` — never matches
# it. That is how this tutorial taught `Container`, `TestContainer.build(`,
# `container.register(…)` and `container.resolve(…)`, all removed in 0.16.0,
# while this script reported it green.
#
# A spelling the framework has deleted is a tutorial that will not compile,
# whatever else passes. Add to this list whenever something is removed.
removed_grep='TestContainer|container\.register\(|container\.resolve\(|container\.pipeline\(|container\.assets\(|container\.uploads\(|container\.registerChannel|alulaRegisterAll|@Inject\("|@Component\(scope:|@Service\(scope:|@Repository\(scope:|@Component\(qualifier:|Lifetime\.'
if hits=$(grep -nE "$removed_grep" TUTORIAL.md); then
  echo "  ✘ tutorial teaches APIs that no longer exist:"
  echo "$hits" | sed 's/^/      /'
  status=1
else
  echo "  ✔ no removed API is taught"
fi

echo "── dependency pins"
# The tutorial tells a reader what to put in Package.swift. The templates are
# built and tested by CI, so they are the version of that truth which cannot
# rot silently — and the tutorial drifting away from them means a reader's
# first Package.swift differs from the one that is actually verified.
python3 - <<'PYPINS'
import re, pathlib, sys

PIN = re.compile(r'Alula-Framework/([a-z-]+)\.git"[^)]*?from:\s*"([0-9][0-9.]*)"', re.S)

def pins(text):
    found = {}
    for repo, version in PIN.findall(text):
        found.setdefault(repo, set()).add(version)
    return found

tutorial = pins(pathlib.Path("TUTORIAL.md").read_text())
template = {}
for manifest in pathlib.Path("templates").rglob("Package.swift"):
    if ".build" in manifest.parts:
        # A locally-built template vendors its dependencies' own manifests
        # here; reading them reports alula-data's pin of alula as if a
        # template had written it.
        continue
    for repo, versions in pins(manifest.read_text()).items():
        template.setdefault(repo, set()).update(versions)

bad = False
for repo, versions in sorted(tutorial.items()):
    expected = template.get(repo)
    if expected is None:
        print(f"  ✘ tutorial pins {repo}, which no template depends on")
        bad = True
    elif not versions <= expected:
        print(f"  ✘ tutorial pins {repo} at {sorted(versions)}, templates use {sorted(expected)}")
        bad = True
sys.exit(1 if bad else 0)
PYPINS
if [ $? -eq 0 ]; then echo "  ✔ tutorial pins match the templates"; else status=1; fi

exit $status

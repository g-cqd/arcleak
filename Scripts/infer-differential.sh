#!/bin/bash
# Differential against Meta Infer's Swift frontend (v1.3+, LLVM-bitcode based).
# Infer's capture phase requires building the target project — run this from a
# machine with Infer installed and the project's build working.
#
#   Scripts/infer-differential.sh <repo> <build-command...>
# e.g.
#   Scripts/infer-differential.sh /tmp/arcleak-dogfood/kickstarter xcodebuild -scheme Kickstarter build
set -euo pipefail

if ! command -v infer >/dev/null; then
  echo "infer not installed — see https://fbinfer.com/docs/getting-started (brew install infer)"
  exit 64
fi

REPO="${1:?usage: infer-differential.sh <repo> <build-command...>}"
shift

cd "$(dirname "$0")/.."
BIN="$(swift build -c release --show-bin-path)/arcleak"
swift build -c release >/dev/null

echo "== arcleak"
"$BIN" analyze "$REPO" --no-cache --format json > /tmp/arcleak-differential.json || true

echo "== infer (capture requires the project build)"
(cd "$REPO" && infer run --pulse -- "$@")

echo "== diff by file:line"
python3 - "$REPO" <<'PY'
import json, sys, os
ours = {(f["path"], f["line"]) for f in json.load(open("/tmp/arcleak-differential.json"))["findings"]}
report = os.path.join(sys.argv[1], "infer-out", "report.json")
theirs = {(i.get("file", ""), i.get("line", 0)) for i in json.load(open(report))
          if "RETAIN" in i.get("bug_type", "")}
print(f"arcleak-only: {len(ours - theirs)}  infer-only: {len(theirs - ours)}  both: {len(ours & theirs)}")
for site in sorted(theirs - ours)[:20]:
    print("  infer-only:", site)
PY
echo "Record the counts and any infer-only sites worth chasing in DESIGN.md."

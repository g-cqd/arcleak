#!/bin/bash
# The identical gate CI runs, executable on any 6.4 machine. Every wave must
# pass this before its commit.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== build (warnings are errors)"
swift build --build-tests

echo "== tests"
swift test

echo "== self-dogfood (strict)"
swift run arcleak analyze Sources --strict --no-cache

echo "== runtime ground-truth oracle"
Scripts/run-leak-oracle.sh "$(swift build --show-bin-path)/leak-oracle"

echo "== lsp smoke"
Scripts/lsp-smoke.sh "$(swift build --show-bin-path)/arcleak"

echo "== GCD prohibition (implementation must use Swift concurrency)"
Scripts/no-gcd.sh

echo "== format lint"
Scripts/lint-format.sh

echo "== all gates green"

#!/bin/bash
# Runtime ground-truth oracle runner (macOS only — uses the `leaks` tool).
# Usage: Scripts/run-leak-oracle.sh <path-to-leak-oracle-binary>
set -uo pipefail

BIN="${1:?usage: run-leak-oracle.sh <leak-oracle binary>}"
fail=0

leak_cycles=$("$BIN" list | awk '$1 == "leak-cycle" {print $2}')
clean_cycles=$("$BIN" list | awk '$1 == "clean-cycle" {print $2}')
contracts=$("$BIN" list | awk '$1 == "contract" {print $2}')

# `leaks` exits non-zero when it finds leaks.
for s in $leak_cycles; do
  if leaks -quiet -atExit -- "$BIN" "$s" >/dev/null 2>&1; then
    echo "FAIL  $s (expected a leak, found none)"
    fail=1
  else
    echo "ok    $s (leaks, as the contract predicts)"
  fi
done

for s in $clean_cycles; do
  if leaks -quiet -atExit -- "$BIN" "$s" >/dev/null 2>&1; then
    echo "ok    $s (clean, as predicted)"
  else
    echo "FAIL  $s (unexpected leak in a clean pattern)"
    fail=1
  fi
done

for s in $contracts; do
  if "$BIN" "$s"; then
    echo "ok    $s (anchor contract held)"
  else
    echo "FAIL  $s (documented anchor contract did NOT hold)"
    fail=1
  fi
done

exit $fail

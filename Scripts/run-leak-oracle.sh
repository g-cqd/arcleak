#!/bin/bash
# Runtime ground-truth oracle runner (macOS only — uses the `leaks` tool).
# Usage: Scripts/run-leak-oracle.sh <path-to-leak-oracle-binary>
#
# Every scenario runs bounded in its own process group: nightly toolchains
# have raced an exit-teardown deadlock under `leaks -atExit` (sometimes
# wedging `leaks`, sometimes orphaning a child), and on CI one survivor
# holds the runner's log pipe and hangs the whole job's finalization.
set -uo pipefail

BIN="${1:?usage: run-leak-oracle.sh <leak-oracle binary>}"
SCENARIO_LIMIT="${ORACLE_SCENARIO_LIMIT:-30}"
fail=0

# Run "$@" in its own process group, killed wholesale after $1 seconds.
# Returns 124 on timeout, the command's status otherwise.
run_bounded() {
  local limit=$1
  shift
  set -m
  "$@" &
  local pid=$!
  set +m
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

leak_cycles=$("$BIN" list | awk '$1 == "leak-cycle" {print $2}')
clean_cycles=$("$BIN" list | awk '$1 == "clean-cycle" {print $2}')
contracts=$("$BIN" list | awk '$1 == "contract" {print $2}')

# `leaks` exits non-zero when it finds leaks; 124 means the scenario wedged.
for s in $leak_cycles; do
  run_bounded "$SCENARIO_LIMIT" leaks -quiet -atExit -- "$BIN" "$s" >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 124 ]; then
    echo "WEDGE $s (killed after ${SCENARIO_LIMIT}s — exit-teardown deadlock)"
    fail=1
  elif [ "$status" -eq 0 ]; then
    echo "FAIL  $s (expected a leak, found none)"
    fail=1
  else
    echo "ok    $s (leaks, as the contract predicts)"
  fi
done

for s in $clean_cycles; do
  run_bounded "$SCENARIO_LIMIT" leaks -quiet -atExit -- "$BIN" "$s" >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 124 ]; then
    echo "WEDGE $s (killed after ${SCENARIO_LIMIT}s — exit-teardown deadlock)"
    fail=1
  elif [ "$status" -eq 0 ]; then
    echo "ok    $s (clean, as predicted)"
  else
    echo "FAIL  $s (unexpected leak in a clean pattern)"
    fail=1
  fi
done

for s in $contracts; do
  run_bounded "$SCENARIO_LIMIT" "$BIN" "$s"
  status=$?
  if [ "$status" -eq 124 ]; then
    echo "WEDGE $s (killed after ${SCENARIO_LIMIT}s — exit-teardown deadlock)"
    fail=1
  elif [ "$status" -eq 0 ]; then
    echo "ok    $s (anchor contract held)"
  else
    echo "FAIL  $s (documented anchor contract did NOT hold)"
    fail=1
  fi
done

# Self-reap: nothing oracle-related may outlive this script (a detached
# survivor is exactly what wedged CI job finalization).
pkill -9 -f "leaks -quiet -atExit" 2>/dev/null
pkill -9 -f "$BIN" 2>/dev/null

exit $fail

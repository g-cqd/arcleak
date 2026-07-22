#!/bin/bash
# Differential against Meta Infer v1.3.0's EXPERIMENTAL Swift frontend
# (LLVM-bitcode based: `capture --llvm-bitcode-file`).
#
# Empirical status (2026-07-23, full evidence in DESIGN.md):
#   - macOS release binaries ship the LLVM frontend STUBBED OUT
#     (Assert_failure LlvmSledgeFrontendStubs.ml) — unusable on macOS.
#   - The Linux x86_64 build has the real frontend but asserts translating
#     Swift class metadata constants from Swift 6.4-beta bitcode
#     (Invariant.Violation llairExp.ml:353, Record/Tuple of opaque pointers)
#     — reproducible with ANY `final class`, i.e. every retain-cycle-relevant
#     module. Re-run when either tool updates.
#
#   Usage: Scripts/infer-differential.sh <swift-file>
# Runs arcleak natively; runs Infer via an amd64 Linux container when the
# Apple `container` CLI and the Linux tarball are available.
set -euo pipefail

FILE="${1:?usage: infer-differential.sh <swift-file>}"
cd "$(dirname "$0")/.."

echo "== arcleak"
swift run -q arcleak analyze "$FILE" --no-cache || true

INFER_LINUX=/tmp/infer-diff/infer-linux-x86_64-v1.3.0/bin/infer
if command -v container >/dev/null && [ -x "$INFER_LINUX" ]; then
  echo "== infer (Linux container, experimental Swift frontend)"
  WORK=$(dirname "$INFER_LINUX")/../..
  cp "$FILE" "$WORK/differential-input.swift"
  xcrun swiftc -emit-bc -parse-as-library "$WORK/differential-input.swift" -o "$WORK/differential-input.bc"
  container run --rm --platform linux/amd64 -v "$WORK":/w -w /w ubuntu:24.04 bash -c \
    "rm -rf infer-out && ./infer-linux-x86_64-v1.3.0/bin/infer capture --llvm-bitcode-file differential-input.bc --llvm-bitcode-source differential-input.swift && ./infer-linux-x86_64-v1.3.0/bin/infer analyze --pulse" \
    || echo "infer capture/analyze failed (expected on Swift 6.4-beta bitcode — see header)"
else
  echo "infer differential environment not present (container CLI + /tmp/infer-diff tarball)"
fi

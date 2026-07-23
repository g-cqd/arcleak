#!/bin/bash
# LSP smoke: initialize + didOpen a leaky document, assert publishDiagnostics
# carries the expected rule, then request a code action and assert the
# deliberate-suppression edit comes back.
set -euo pipefail

BIN="${1:?usage: lsp-smoke.sh <arcleak binary>}"

python3 - "$BIN" <<'EOF'
import json, subprocess, sys

proc = subprocess.Popen(
    [sys.argv[1], "lsp"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
)

def send(payload):
    body = json.dumps(payload).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()

def read():
    header = b""
    while not header.endswith(b"\r\n\r\n"):
        byte = proc.stdout.read(1)
        if not byte:
            raise SystemExit("server closed unexpectedly")
        header += byte
    length = int([l for l in header.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
    return json.loads(proc.stdout.read(length))

leaky = "final class Box {\n    var handler: (() -> Void)?\n    func arm() {\n        handler = { self.fire() }\n    }\n    func fire() {}\n}\n"
uri = "file:///tmp/lsp-smoke.swift"

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
init_response = read()
assert init_response["result"]["capabilities"]["codeActionProvider"] is True, init_response

send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": uri, "text": leaky}}})
diagnostics = read()
assert diagnostics["method"] == "textDocument/publishDiagnostics", diagnostics
codes = [d["code"] for d in diagnostics["params"]["diagnostics"]]
assert "stored-closure-strong-self" in codes, codes
line = diagnostics["params"]["diagnostics"][0]["range"]["start"]["line"]

send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/codeAction",
      "params": {"textDocument": {"uri": uri},
                 "range": {"start": {"line": line, "character": 0},
                           "end": {"line": line, "character": 1}}}})
actions = read()
assert actions["result"], actions
edit = actions["result"][0]["edit"]["changes"][uri][0]["newText"]
assert "arcleak:deliberate" in edit, edit

# didClose must clear diagnostics (and drop the in-memory document).
send({"jsonrpc": "2.0", "method": "textDocument/didClose",
      "params": {"textDocument": {"uri": uri}}})
cleared = read()
assert cleared["method"] == "textDocument/publishDiagnostics", cleared
assert cleared["params"]["diagnostics"] == [], cleared

# Oversized Content-Length must drop the connection cleanly (no OOM, no hang).
big = json.dumps({"jsonrpc": "2.0", "id": 9, "method": "initialize", "params": {}}).encode()
proc.stdin.write(b"Content-Length: 99999999999\r\n\r\n" + big)
proc.stdin.flush()
proc.wait(timeout=5)
assert proc.returncode is not None, "server should exit on absurd Content-Length"
print("lsp smoke: ok (diagnostics + code action + didClose + oversized-length drop)")
EOF

# arcleak

Static ARC analysis for Swift, built on [swift-syntax]. Analysis is
source-level: no build, no index, no project file required.

Three families of memory bugs:

- **Retain cycles** — closures stored on `self` capturing `self` strongly,
  Combine `sink`/`assign(to:on:)` cancellables stored on `self`,
  non-terminating `Task`s whose handle lives on `self`.
- **Anchor leaks** — immortal framework objects keeping yours alive: repeating
  `Timer`/`CADisplayLink` targets and blocks, block-based `NotificationCenter`
  observers, `URLSession` delegates. Cleanup that exists only in `deinit` is a
  *definite* leak — `deinit` cannot run while the anchor holds `self`.
- **Premature releases** — the inverse bug: lifetime tokens (`AnyCancellable`,
  `NSKeyValueObservation`, observer handles) discarded or bound to storage
  that dies at scope end, silently stopping the work they own.

What arcleak deliberately does **not** flag: transient escapes (completion
handlers, finite `Task`s — deferred deallocation, not leaks), non-escaping
closures, value-type `self` (SwiftUI bodies), the same-lifetime
`[unowned self]` pattern, sinks over provably finite pipelines, SwiftData
`@Model` relationships (macro-managed storage), and tokens that are a
function's return value. A clean-fixture corpus gates false positives in CI.

Every retention contract the rules encode is runtime-proven: the leak oracle
(`Scripts/run-leak-oracle.sh`) reconstructs each one and verifies it with
`leaks -atExit` and deinit canaries on every macOS CI run.

## Requirements

Swift 6.4 toolchain, macOS 14+ or Linux. No released toolchain ships tools
6.4 yet; the repo pins a swiftly snapshot via `.swift-version` (build with
`swiftly run swift build`), and CI runs nightly toolchains.

## CLI

```sh
arcleak analyze Sources             # xcode-format diagnostics, exit 1 on errors
arcleak analyze --format json .     # machine-readable report (also: --format sarif)
arcleak analyze --strict Sources    # exit 1 on any finding
arcleak analyze --fix Sources       # apply [weak self] fix-its (--fix-dry-run to preview)
arcleak rules                       # list rules, severities, suppression syntax
arcleak rules timer-retains-self    # one rule's retention contract and fix
arcleak lsp                         # LSP server over stdio: diagnostics + accept quick-fix
```

Exit codes: `0` clean or warnings-only, `1` error-severity findings (or any
finding with `--strict`), `64+` usage/configuration failures.

**Baseline** — adopt on a legacy codebase by accepting current debt and
gating only new findings:

```sh
arcleak analyze Sources --write-baseline .arcleak-baseline.json
arcleak analyze Sources --baseline .arcleak-baseline.json   # CI: only new bugs fail
```

Baseline fingerprints include positions, so large refactors shift findings
out of the baseline — regenerate deliberately rather than let fuzzy matching
swallow new bugs.

**Cache** — on by default (`~/Library/Caches/arcleak/facts.json`; override
with `--cache-path`, disable with `--no-cache`). Only parsed facts are
cached, keyed by content fingerprint and tool version; rules always re-run,
so findings never go stale relative to rules or configuration. The cache
fails open: corrupt or mismatched caches behave as empty.

## Build-time integration

**SwiftPM build-tool plugin** — diagnostics appear inline in every build;
error-severity findings fail the build:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/g-cqd/arcleak.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "App",
        plugins: [.plugin(name: "ArcLeakBuildToolPlugin", package: "arcleak")]
    ),
]
```

On demand: `swift package arcleak [paths…]`. For non-SwiftPM projects, an
Xcode run-script phase invoking `arcleak analyze "${SRCROOT}/Sources"` does
the same. A composite GitHub Action ships in `action.yml` (build, analyze,
SARIF upload to code scanning).

## Accepting a finding

Directives use the `@` sigil with the `@al:` or `@arcleak:` namespace
(synonyms). `accept` documents an intentional strong reference with an
auditable reason; it covers the flagged line and the next, so it works
trailing on the code or on the line above:

```swift
// @al:accept -- owner tears this down in shutdown(); lifetime is intentional
onTick = { self.tick() }
```

Precise forms, optionally scoped to rule ids:

```swift
// @al:accept:this timer-retains-self -- invalidated by the scene lifecycle
// @al:accept:next stored-closure-strong-self
// @al:disable combine-sink-self-cycle
…
// @al:enable combine-sink-self-cycle
```

Accepted findings are not dropped: they are counted in the summary and
carried, with reasons, in the JSON report. A directive naming only unknown
rule ids accepts nothing. Test fixtures use a separate `#` sigil for runner
expectations (`// #al:expect <rule>`), so assertions and directives cannot
collide.

## Configuration (`.arcleak.json`)

```json
{
  "rules": {
    "task-nonterminating-self": { "severity": "error" },
    "token-stored-in-local": { "enabled": false }
  },
  "exclude": ["Generated/", "Tests/Fixtures/"]
}
```

Read from `--config` or `./.arcleak.json`. Unknown rule ids are a hard error.
The definite-leak upgrade (cleanup only reachable from an unreachable
`deinit`) reports as `error` regardless of configured severity; use a
directive if it is truly intentional.

## Rules

| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]` |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; the center holds block and token until removal |
| `task-nonterminating-self` | warning† | `while true`/`for await` `Task` capturing `self` strongly |
| `unstored-lifetime-token` | warning | lifetime token discarded — from framework APIs or same-file functions whose return type is a token |
| `token-stored-in-local` | warning | token bound to storage that dies at scope end, or to a local captured by an escaping closure (never removed → unbounded growth) |
| `mutual-strong-properties` | warning | cross-file ownership-graph cycle: strong stored properties whose types point at each other, reported with the retention path |
| `urlsession-delegate-leak` | warning† | `URLSession(configuration:delegate: self, …)` with no reachable invalidation |
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure — traps if `self` deallocates first |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
capture pipeline as closures.

† upgraded to **error** when the only release call sits in `deinit` (or the
task handle is stored on `self`) — the release is unreachable by construction.

## Limits

Cross-file cycle detection covers the analyzed corpus: every file passed in
one run. Types, weak-ness, and class-ness declared in other modules and the
SDK are outside it, as is release-call reachability across files.
`mutual-strong-properties` is type-level: an SCC proves the types *can*
cycle; verify instance ownership before restructuring. Analysis is of
written source — macro-generated storage is invisible (SwiftData `@Model` is
special-cased). Silence is not proof of absence; confirm with
Instruments/`leaks` for runtime ground truth.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax

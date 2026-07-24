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

Swift 6.4 toolchain, macOS 15+ or Linux. No released toolchain ships tools
6.4 yet; the repo pins a swiftly snapshot via `.swift-version` (build with
`swiftly run swift build`), and CI runs nightly toolchains.

> **Platform floor.** The floor is **macOS 15** (raised from 14 in 0.3.0): the
> opt-in `--index-store` backend links IndexStoreDB, whose target floor is
> macOS 15. arcleak is a developer tool, so the bump is deliberate and
> acceptable. The default syntax-only analysis is unaffected, and Linux builds
> gate the index out entirely (`#if canImport(IndexStoreDB)`) with no behavior
> change.

## CLI

```sh
arcleak analyze Sources             # xcode-format diagnostics, exit 1 on errors
arcleak analyze --format json .     # machine-readable report (also: --format sarif)
arcleak analyze --strict Sources    # exit 1 on any finding
arcleak analyze --fix Sources       # apply [weak self] fix-its (--fix-dry-run to preview)
arcleak analyze --index-store .     # resolve cross-module types via the index (macOS-only)
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

## Cross-module resolution (`--index-store`, macOS-only)

By default arcleak reasons only about types declared in the analyzed corpus —
a stored property whose type lives in another module or the SDK is skipped as
unknown. `--index-store` consults the IndexStoreDB index that SourceKit-LSP /
`swift build` already produce to resolve those types' class-ness, so a strong
stored property pointing at a class in another module can complete a
cross-module `mutual-strong-properties` cycle:

```sh
arcleak analyze Sources --index-store                       # discover the store (.build/…, DerivedData)
arcleak analyze Sources --index-store-path .build/index/store   # explicit store
arcleak analyze Sources --index-store-build                 # `swift build` one first if missing
```

It is **opt-in, macOS-only, and always fails open**. With no index, on Linux,
or when the store is stale relative to the analyzed sources, arcleak prints a
one-line note and runs the corpus-only analysis unchanged — byte-identical to
the default. Resolution is conservative: an edge is added only when the index
**confirms** a type is a class/actor, never on a guess. The dylib
(`libIndexStore.dylib`) is loaded from your active toolchain (a regular file
owned by root or you, not world-writable).

## Experimental: `--experimental-embedding-rank` (macOS-only)

Groups findings of similar shape together in the report using on-device
embeddings (`NLContextualEmbedding`; zero download, with a deterministic
fallback offline). This is **ordering only** — it never changes which findings
fire, their severity, or the exit code. Experimental and off by default.

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

### Custom retention contracts (`contracts`)

arcleak's knowledge base keys on literal API shapes (`.sink`, `.assign`,
`Timer`, …). Codebases that **wrap** those APIs in a helper hide the shape from
the matcher — a hand-rolled `React.to`, a `bind(...)`, a `Reactor` type. Declare
the wrapper and arcleak sees through the indirection. Contracts are **opt-in and
fail closed**: a malformed contract is a typed error, and without a contract
arcleak stays silent rather than guess at a wrapper it cannot prove.

```json
{
  "rules": {},
  "exclude": [],
  "contracts": [
    {
      "callee": "to",
      "base": "React",
      "template": "sinkWrapper",
      "tokenName": "the React.to subscription"
    }
  ]
}
```

Fields: `callee` (required — the method name, `to` in `React.to(…)`), `base`
(optional receiver, `React` for the static call), `requiredLabels` (optional —
all must be present to match), `tokenName` (optional diagnostic name), and
`template`:

- **`tokenProducer`** — the call returns a lifetime token that must be owned.
  Feeds the premature-release rules: a discarded or scope-local token is flagged
  exactly like a dropped `AnyCancellable`.
- **`sinkWrapper`** — a custom Combine wrapper that wraps `.sink`/`.assign`. A
  superset of `tokenProducer`: the returned token still feeds premature-release,
  **and** the wrapper's closure is analyzed for strong-`self` capture. When the
  token is stored on `self` and the closure captures `self` strongly, arcleak
  reports `combine-sink-self-cycle` — the same cycle it catches for a literal
  `.sink`. Because the real upstream is hidden inside the wrapper, completion is
  unknown, so the finding is a `warning` with an explicit "completion could not
  be determined" note rather than an over-claimed `error`.

With the contract above, `becomeInactiveTask = React.to(.willResignActive) { _ in
self.disconnect() }` (the `AnyCancellable` stored on `self`, the closure
capturing `self` strongly) is flagged; the same call with `[weak self]` is not.

## Recommended configuration for real-world use

- **Default (syntax, corpus-only) — best for CI gating.** With no
  configuration, arcleak is high-precision and produces **zero false positives
  on clean code** (verified: 0 findings across Luce, Kyklos, LotoBuddy, and
  Stations). It catches direct `.sink`/`.assign`, `Timer`/`CADisplayLink`,
  block-based `NotificationCenter`, `URLSession` delegates, non-terminating
  `Task`s, and stored-closure/bound-method `self`-cycles. Gate CI on this.
- **Custom Combine wrappers — add a `sinkWrapper` contract.** If your codebase
  wraps `.sink` in a helper (`React.to`, `bind`, a `Reactor`), declare it as a
  `sinkWrapper` contract (see the exact config above) so arcleak sees through
  the indirection and flags strong-`self` cycles hidden by the wrapper. Without
  the contract arcleak conservatively stays silent rather than invent a cycle it
  cannot prove — so a wrapper-heavy codebase reads as clean until you teach it
  the wrapper.
- **Cross-module types — enable `--index-store` (macOS).** For retain cycles
  that close through types declared in other modules or the SDK, `--index-store`
  resolves their class-ness from the build index (see above). It is opt-in and
  **fails open**: with no index, on Linux, or against a stale store it runs the
  corpus-only analysis unchanged.
- **True-negative discipline.** arcleak reports nothing it cannot prove, so
  **silence means "no provable cycle in what I can see," not "no cycles."** A
  wrapper it does not know, a cycle that closes through an unresolved module, or
  storage created by a macro can all hide a real leak. Pair arcleak with
  Instruments / `leaks` for runtime ground truth on wrapper-heavy code.

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
SDK are outside it by default — the opt-in macOS `--index-store` backend
resolves class-ness for those (see above); release-call reachability across
files remains corpus-only.
`mutual-strong-properties` is type-level: an SCC proves the types *can*
cycle; verify instance ownership before restructuring. Analysis is of
written source — macro-generated storage is invisible (SwiftData `@Model` is
special-cased).

Two indirection gaps are known and deliberate rather than silently wrong.
Custom `.sink`/`.assign` **wrappers** hide the API shape from the matcher —
opt in with a `sinkWrapper` contract (above) so arcleak analyzes the wrapper's
closure. A bound method buried in a **collection literal handed to a
constructor** whose result is stored on `self` (`self.router = Router([.k:
self.method])` — the Stations `PlaybackService`/`Reactor` shape) is not
tracked: proving the cycle needs the constructed type's storage semantics
(does it retain the collection, and does the work it feeds outlive the owner?),
which is cross-type ownership arcleak does not model — flagging it
unconditionally would false-positive on the many constructors that consume
closures transiently. Direct bound-method storage (`self.handler =
self.method`) and bound methods handed straight to a token API
(`sink(receiveValue: handle)`) are caught.

Silence is not proof of absence; confirm with Instruments/`leaks` for runtime
ground truth.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax

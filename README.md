# arcleak

Static ARC analysis for Swift, built on [swift-syntax]. Detects the three
families of memory bugs the compiler stays silent about:

- **Retain cycles** — closures stored on `self` capturing `self` strongly,
  Combine `sink`/`assign(to:on:)` cancellables stored on `self`,
  non-terminating `Task`s whose handle lives on `self`.
- **Anchor leaks** — immortal framework objects keeping yours alive: repeating
  `Timer`/`CADisplayLink` targets and blocks (run loop → timer → self),
  block-based `NotificationCenter` observers ("the center strongly holds the
  copied block until you remove the observer registration"). Cleanup that only
  exists in `deinit` is called out as a *definite* leak — `deinit` can never
  run while the anchor holds `self`.
- **Premature releases** — the inverse bug: lifetime tokens (`AnyCancellable`,
  `NSKeyValueObservation`, observer handles) discarded or stored in a local
  that dies at scope end, silently stopping the work they own.

Equally important is what arcleak deliberately does **not** flag: transient
escapes (`DispatchQueue.async`, completion handlers, finite `Task`s — deferred
deallocation, not leaks), non-escaping closures, value-type `self` (SwiftUI
bodies), and the Swift-book-blessed `[unowned self]` same-lifetime pattern.
Blanket `[weak self]` linting is cargo cult; the clean-fixture corpus gates
false positives in CI.

Every retention contract the rules encode is *runtime-proven*: the leak
oracle (`Scripts/run-leak-oracle.sh`) reconstructs each one and verifies it
with `leaks -atExit` and in-process deinit canaries on every CI run, so an OS
behavior change breaks this repo's CI — not your trust.

## Requirements

Swift 6.4 toolchain, macOS 14+ (analysis is source-level — no build of the
target project is required).

## CLI

```sh
swift run arcleak analyze Sources            # xcode-format diagnostics, exit 1 on errors
swift run arcleak analyze --format json .    # machine-readable report (also: --format sarif)
swift run arcleak analyze --strict Sources   # exit 1 on any finding
swift run arcleak rules                      # list rules, severities, suppression syntax
swift run arcleak explain timer-retains-self # retention contract, why it bites, the fix
swift run arcleak analyze --fix Sources      # apply [weak self] fix-its in place (--fix-dry-run to preview)
swift run arcleak lsp                        # minimal LSP server: diagnostics + deliberate-suppression quick fix
swift run arcleak generate-repro --finding <fp> --report r.json  # deinit-canary test skeleton
```

`explain --finding <fingerprint> --report <json>` prints one finding's full
story (location, message, contract citation); fingerprints are in every JSON
report. A composite GitHub Action ships in `action.yml` (build, analyze,
SARIF upload); release process in `Docs/RELEASING.md`.

**Adopting on a legacy codebase** — accept current debt, gate only new findings:

```sh
arcleak analyze Sources --write-baseline .arcleak-baseline.json   # accept today's findings
arcleak analyze Sources --baseline .arcleak-baseline.json         # CI: only new bugs fail
```

Baseline fingerprints include positions, so large refactors shift findings out
of the baseline — regenerate deliberately rather than have fuzzy matching
swallow new bugs. `--format sarif` uploads to GitHub code scanning.

**Incremental cache** — on by default (`~/Library/Caches/arcleak/facts.json`;
override with `--cache-path`, disable with `--no-cache`). Only parsed *facts*
are cached, keyed by content fingerprint and tool version; rules always
re-run, so findings can never go stale relative to rules or configuration.
The cache fails open: a corrupt or mismatched cache behaves as empty. The
build-tool plugin keeps its cache in the plugin work directory automatically.

Exit codes: `0` clean or warnings-only, `1` error-severity findings (or any
finding with `--strict`), `64+` usage/configuration failures. Configuration is
read from `--config` or `./.arcleak.json`.

## Engineering standards

Swift 6 language mode on a 6.4 toolchain, warnings-as-errors, and the
upcoming-feature set enabled package-wide (`ExistentialAny`,
`InternalImportsByDefault`, `MemberImportVisibility`, plus the future
concurrency defaults `InferIsolatedConformances` and
`NonisolatedNonsendingByDefault`) with `strictMemorySafety()` — the analyzer
holds itself to a zero-unsafe, zero-warning bar and dogfoods itself.
**GCD is prohibited in the implementation** (CI-gated by `Scripts/no-gcd.sh`):
concurrency is structured Swift concurrency only — the sole sanctioned
Dispatch usage is oracle scenarios and fixtures that reproduce GCD retention
contracts as test subject matter.

## Build-time integration

**SwiftPM build-tool plugin** — diagnostics appear inline in every build, like
the compiler's own; error-severity findings fail the build, warnings don't:

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

**On demand**: `swift package arcleak [paths…]`.

Note: `package:` must be the package *identity* — `"arcleak"` for a URL
dependency on `arcleak.git`, but the checkout directory name for a
`.package(path:)` dependency.

**Xcode run-script phase** (non-SwiftPM projects):

```sh
if command -v arcleak >/dev/null; then
  arcleak analyze "${SRCROOT}/Sources"
fi
```

## Accepting a finding (the `@` directive DSL)

Directives to the analyzer use the `@` sigil and either the `@al:` or the
`@arcleak:` namespace (synonyms). `accept` documents an intentional strong
reference with an auditable reason; it covers the flagged line **and** the next,
so it works trailing on the code or on the line above:

```swift
// @al:accept -- owner tears this down in shutdown(); lifetime is intentional
onTick = { self.tick() }
```

Precise forms (optionally scoped to specific rule ids):

```swift
// @al:accept:this timer-retains-self -- invalidated by the scene lifecycle
// @al:accept:next stored-closure-strong-self
// @al:disable combine-sink-self-cycle
…
// @al:enable combine-sink-self-cycle
```

Accepted findings are not dropped: they are counted in the summary and carried
(with their reasons) in the JSON report, so acceptance debt stays visible. A
directive naming only unknown rule ids accepts **nothing**.

Test fixtures use a separate `#` sigil for expectations the fixture runner
asserts (`// #al:expect <rule>`, `// #al:expect-suppressed <rule>`) — the `#`
vs `@` split keeps assertions and directives from ever colliding.

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

Unknown rule ids are a hard error — a typo cannot silently disable nothing.
Note: the definite-leak upgrade (cleanup only reachable from an unreachable
`deinit`) reports as `error` regardless of configured severity; use a
suppression directive if it is truly intentional.

## Rules

| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; center holds block+token until removal |
| `task-nonterminating-self` | warning† | `while true`/`for await` `Task` capturing `self` strongly (Task bodies capture `self` implicitly) |
| `unstored-lifetime-token` | warning | lifetime token discarded (`_ =` / statement position) |
| `token-stored-in-local` | warning | lifetime token bound to a local (or local `store(in:)`) that dies at scope end |
| `mutual-strong-properties` | warning | **cross-file** cycle in the ownership graph: strong stored properties whose types point at each other (`A.b: B`, `B.a: A`), reported with the full retention path |
| `urlsession-delegate-leak` | warning† | `URLSession(configuration:delegate: self, …)` with no reachable session invalidation — the docs mandate this: "your app leaks memory until it exits" |
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure (timer, notification center, time observer) — traps if `self` deallocates first |
| `dead-weak-capture` | warning, **opt-in** | `[weak self]` whose body never uses `self` — capture-list noise |
| `delegate-strong-property` | warning, **opt-in** | strong stored property named/typed like a delegate (name heuristic until the index layer) |

Bound method references (`handler = self.method`, `sink(receiveValue: handle)`)
and self-referencing local functions passed as values are folded into the same
capture pipeline — they fire the existing stored-closure/cycle rules with
method-reference-specific fix guidance, no separate rule id needed.

† upgraded to **error** when the only release call sits in `deinit` (or the
task handle is stored on `self`) — the release is unreachable by construction.

## Current limits (by design)

Cross-file cycle detection covers the **analyzed corpus** (every file passed in
one run): the ownership graph links type names across those files without any
build or index. What still needs the index-store backend (next phase): types,
weak-ness, and class-ness declared in *other modules and the SDK*, and
release-call reachability across files. `mutual-strong-properties` is
type-level analysis — an SCC proves the types *can* cycle; verify instance
ownership before restructuring. Analysis is of written source —
macro-generated storage is invisible. Silence is not a proof of absence;
confirm with Instruments/`leaks` for runtime ground truth.


## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax

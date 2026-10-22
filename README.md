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
arcleak analyze --strict Sources    # exit 1 on any warning or error; notes never fail
arcleak analyze --fix Sources       # apply [weak self] fix-its (--fix-dry-run to preview)
arcleak analyze --index-store .     # resolve cross-module types via the index (macOS-only)
arcleak rules                       # list rules, severities, suppression syntax
arcleak rules timer-retains-self    # one rule's retention contract and fix
arcleak lsp                         # LSP server over stdio: diagnostics + accept quick-fix
```

Exit codes: `0` clean or warnings and notes only, `1` error-severity findings
(or any warning with `--strict`), and `64`, `70`, `74` or `78` when the gate itself
broke — see [Exit codes](#exit-codes).

**Project context** — where a type lives changes what its leak costs.
Directory arguments are searched for project files as well as Swift files:
Xcode projects, package manifests, Info.plists, storyboards and xibs (or pass
them explicitly).

- `#if os(...)` follows the platforms the project builds for (an Xcode
  project's `SDKROOT`, a manifest's `platforms`), else the host's; the
  `platforms` configuration key overrides both.
- The debug build is analyzed, `DEBUG` set, and a finding in `#if DEBUG` code
  says only debug builds compile it; `"debugBuild": false` analyzes the
  release build instead.
- Findings in previews and in generated files are withheld, listed with the
  suppressed findings and the reason.
- A finding in test code (a file importing XCTest or Testing, or a test path)
  says so.
- A class a project file tells the system to create (an extension's principal
  class, a scene delegate, a storyboard custom class) lives for the whole
  process or extension: its findings are notes, which never fail a run.

**Baseline** — adopt on a legacy codebase by accepting current debt and
gating only new findings:

```sh
arcleak analyze Sources --write-baseline .arcleak-baseline.json
arcleak analyze Sources --baseline .arcleak-baseline.json   # CI: only new bugs fail
```

Baseline fingerprints include positions, so large refactors shift findings
out of the baseline — regenerate deliberately rather than let fuzzy matching
swallow new bugs.

**Cache** — on by default, one per workspace
(`~/Library/Caches/arcleak/<key>/facts.json` on macOS, the platform's caches
directory elsewhere; override with
`--cache-path`, disable with `--no-cache`). Only parsed facts are cached. Each
file's entry is keyed by its content and by the configuration facts depend on
(`defines`, `debugBuild`, `platforms`, `contracts`); the whole cache is keyed by the arcleak build that
wrote it — its executable, not just its version — so a rebuilt or reinstalled
arcleak starts cold rather than trust facts another build extracted. A run
over part of the workspace keeps the other files' entries; only entries of
deleted files are dropped. A cache larger than 64 MiB is neither read nor
written. Rules always re-run, so findings never go stale relative to rules or
configuration.
The cache fails open. Its first line names the build that wrote it and is
checked before anything is decoded, so another build's cache, or a file that
is no cache at all, is ignored without a word; this build's cache that still
cannot be read or decoded — truncated or the wrong JSON shape, say — is
reported once on stderr and rewritten. Either way the run parses every file
afresh.

## CLI and JSON contract (1.x)

The contract is versioned by the JSON `schemaVersion` (currently 1) and holds from this release on; arcleak's own version number may still be 0.x.

Within 1.x, `arcleak analyze <paths…>`, the flags below, the exit codes and the JSON fields do not change incompatibly. Adding a flag or a field is not a breaking change.

JSON goes to stdout and stderr is free-form text, so do not merge them with `2>&1`; a document without `schemaVersion` is not a 1.x report. Outside the freeze: flags not listed in this section (`--define`, `--stamp`, `--experimental-*`), the `rules` and `lsp` subcommands, and the ArcLeakCore library API.

| Flag | Meaning |
|---|---|
| `--format` | `xcode` (default, build-log lines), `json` (the report below) or `sarif` (SARIF 2.1.0) |
| `--only <path>`, `--only-from <file>` | report only these files; repeatable, or one path per line (`-` reads stdin). See [Report scope](#report-scope) |
| `--relative-to <dir>` | print paths relative to `<dir>`; see [Fingerprints](#fingerprints-are-portable-by-default) |
| `--baseline <file>`, `--write-baseline <file>` | drop accepted findings; write the current findings as a baseline, then exit `0` |
| `--config <file>` | configuration file; default `./.arcleak.json` when present |
| `--cache-path <file>`, `--no-cache` | facts-cache file; disable the cache. See [Facts cache](#facts-cache-and-parallel-jobs) |
| `--strict` | warnings fail the gate too; notes never do |
| `--include <regions>`, `--exclude <regions>` | `preview`, `debug`, `test`, `mock`, `generated`, `script` or `all`: analyze as first-class code, or keep out of scope |

### Exit status

The exit codes and their meanings are listed in [Exit codes](#exit-codes); within 1.x they do not change incompatibly.

### Report scope

- The whole corpus is analyzed; only the report is scoped, because the ownership graph spans files.
- A finding is kept when any of its locations (primary or `related`) is in scope. Only kept findings decide the exit code.
- Scope entries are canonicalized like finding paths, so `--relative-to` changes how paths print, never which findings are kept.
- An empty scope (an empty `--only-from` file) keeps nothing: an empty report and exit `0`.
- Out-of-scope findings are not printed; the JSON report lists them in `outOfScope`, and the summary counts them.
- Scope entries resolve against the working directory, but `git diff --name-only` prints repository-root-relative paths: run from the repository root, or use `git diff --relative`. A scope that matches no analyzed file prints a warning to stderr and exits `0`.

### JSON report

`--format json` prints one object. Optional keys are omitted when they have no value, never written as `null`.

| Field | Meaning |
|---|---|
| `schemaVersion` | integer, `1` today |
| `findings` | reported findings: in scope, not suppressed, not baselined |
| `suppressed` | findings silenced by a suppression comment, each with `finding` and `reason`; `reason` is optional, omitted when the directive gave none |
| `outOfScope` | findings outside `--only` / `--only-from` |
| `degradedFiles` | files skipped or read with errors, each with `path` and `detail` |
| `analyzedFileCount` | files analyzed |
| `cacheHits`, `cacheMisses` | facts reused from the cache, and facts parsed |
| `cacheLoadFailure` | optional string; present only when the facts cache was ignored as unreadable or undecodable; omitted otherwise |
| `wasCancelled` | `false` in every printed report: a cancelled run prints nothing and exits `70` |

Each element of `findings`:

| Field | Meaning |
|---|---|
| `rule`, `severity` | rule id (`arcleak rules` lists them); `note`, `warning` or `error` |
| `path`, `line`, `column` | location, absolute or relative to `--relative-to`; `line` and `column` are 1-based, `column` counts UTF-8 bytes |
| `message` | one-line description |
| `note` | optional; omitted when there is none |
| `related` | optional `[{path, line, column}]` of the other locations; omitted when empty |
| `fingerprintPath` | optional; the path the fingerprint hashes. Set inside a git repository (relative to its root) and for paths under a `--relative-to` directory; omitted otherwise |
| `fingerprint` | stable identity; equals the value `--baseline` matches unless `--relative-to` names a directory other than the repository root. Outside a repository, `--relative-to` also makes the printed fingerprint differ from the baseline's |

`schemaVersion` is shared by arcleak, dolly and deadwood. It changes only when a field is removed, renamed, retyped, made required or optional, or changes meaning, or the closed set of severities changes; rule ids are an open set (a new rule can appear in any 1.x release, so consumers must handle unknown rule ids); consumers ignore unknown fields and reject a higher `schemaVersion`.

### Facts cache and parallel jobs

- The default cache is `~/Library/Caches/arcleak/<key>/facts.json` on macOS, and under the platform's caches directory elsewhere. The key identifies the git repository of the working directory (the directory itself outside one), so all its subdirectories share one cache.
- Entries are keyed by path and validated against the file's content and the configuration (`defines`, `debugBuild`, `platforms`, `contracts`). A cache written by another arcleak build is ignored whole; a stale or torn entry is never served.
- Writes are atomic and replace the whole file: concurrent runs can lose each other's new entries (the last writer wins), but never read wrong facts.
- Parallel CI jobs on one machine: give each its own `--cache-path`, which avoids lost updates and evictions. `--no-cache` disables the cache; a file over 64 MiB is neither read nor written.

### Baselines and fingerprints

- `fingerprint` hashes the rule, the path, `line`, `column` and `message`. `--baseline` and `--write-baseline` match on the repository-relative path (absolute outside a repository), so a baseline is the same with or without `--relative-to`.
- The printed `fingerprint` and `fingerprintPath` of `--format json` and SARIF do follow `--relative-to`: do not compare them with a baseline file.
- Because `line` and `column` are hashed, an edit above a baselined finding re-surfaces it; regenerate the baseline after large refactors.
- New findings only (findings not present at the same position on the base branch): on the base branch, `arcleak analyze . --write-baseline base.json` (unscoped); on the pull request, `arcleak analyze . --baseline base.json --only-from changed.txt`. An edit above a pre-existing finding in a changed file re-surfaces it, because the fingerprint includes line and column.

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

Groups findings of similar shape together in the report by embedding each
finding's flagged-site line and clustering by cosine similarity. This is
**ordering only** — it never changes which findings fire, their severity, or
the exit code. Experimental and off by default.

Out of the box it uses Apple's on-device `NLContextualEmbedding` (zero
download, with a deterministic n-gram fallback when the system asset is
missing). Be aware of what that model is: an **English natural-language**
model. It reads source lines as prose, so it over-clusters — anything that
"looks like a statement" lands in one narrow cone of the vector space. A
code-trained sentence model groups noticeably tighter, and being far smaller,
runs several times faster.

So `--embedding-bundle` takes a directory holding a Core ML model plus the
WordPiece vocabulary it was trained with — a `.mlpackage` (compiled on first
use) or `.mlmodelc`, alongside `vocab.txt` / `tokenizer.json` / `config.json`.

**WordPiece (BERT-family) bundles**, e.g. all-MiniLM-L6-v2. arcleak tokenizes
in-house (`WordPieceTokenizer`, pinned token-for-token against
`swift-transformers` before that dependency was dropped) rather than linking a
9-package HuggingFace stack into every binary. A BPE or SentencePiece bundle
fails to load and falls back to the zero-download provider rather than
tokenizing wrongly.

> **Pick a *sentence-embedding* model, not a masked-LM checkpoint.** "Code-trained"
> is not the property that matters — cosine-comparability is. Byte-level BPE support
> shipped briefly in v0.6.0 to allow CodeBERT, then was withdrawn once measured: on
> the same 29-finding corpus the anomaly-score spread was all-MiniLM-L6-v2 **36-77%**
> (stdev 10.96), Apple NLContextual 2-8% (stdev 1.76), and **CodeBERT 1-3%
> (stdev 0.68)** — the worst of the three. A masked-LM checkpoint produces
> anisotropic vectors: everything crowds into one narrow cone and every pair looks
> similar. MiniLM is contrastively fine-tuned for exactly this use:

```sh
arcleak analyze Sources --experimental-embedding-rank \
    --embedding-bundle /path/to/Models/MiniLM
export ARCLEAK_EMBEDDING_BUNDLE=/path/to/Models/MiniLM   # same, without the flag
```

A build that ships a model next to the binary needs neither: `Models/MiniLM`
beside the executable, or `share/arcleak/Models/MiniLM` for a `bin/`+`share/`
install, is discovered automatically. Precedence is
`--embedding-bundle` → `ARCLEAK_EMBEDDING_BUNDLE` → executable-adjacent →
`NLContextualEmbedding` → deterministic fallback, and the run's status note
names the model that actually ran:

```
arcleak: experimental embedding-rank grouped 12 finding(s) by flagged-site similarity [provider: bundle:MiniLM]
```

A bundle that fails to load is reported and ignored — ranking falls back to
the default provider, and the finding set and exit code are untouched. The
flag has no effect without `--experimental-embedding-rank`, and none of this
exists on Linux (`#if canImport(CoreML)`), where the flag is accepted and
ranking is skipped with a note.

## Build-time integration

**SwiftPM build-tool plugin** — diagnostics appear inline in every build;
error-severity findings fail the build:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/g-cqd/arcleak.git", from: "0.10.1"),
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

**Limits of the build-tool plugin.** It analyzes one target's sources per run, so `mutual-strong-properties` cycles that cross targets are invisible to it, and there is no Xcode plugin for the same reason. Treat the whole-repository CI gate as authoritative: run `arcleak analyze . --only-from changed.txt …` in CI or pre-push (see [the pull-request gate](#using-it-as-a-pull-request-gate)).

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
- **`disposeBag`** — an RxSwift-style subscription whose closure is analyzed
  for strong-`self` capture and whose Disposable goes into a bag on `self`
  through a chained `.disposed(by:)` or `addDisposableTo(_:)`, or is assigned to
  a member of `self`. Reports `combine-sink-self-cycle` as a `warning`; silent
  for finite sources (`Single`, `Completable`, `Maybe`, `just`, `take(1)`,
  `first()`, `subscribe(onSuccess:)`). Built in for `subscribe`, `bind` and
  `drive`.
- **`signalDisposable`** — a SwiftSignalKit-style subscription whose
  Disposable is passed to `self.<disposable>.set(_:)` or `.add(_:)`, or assigned
  to a member of `self`. Same report and finiteness rules. Built in for
  `start(next:)` (declare it with `"requiredLabels": ["next"]` for other
  callees of that shape).

A dropped reactive Disposable does not end its subscription, so the two
reactive templates feed only the cycle rule, never the premature-release rules.

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
| `stored-closure-strong-self` | error‡ | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly; also one level down, on a child `self` owns through a strong stored property (`self.toolbar.onTap = { self… }`, `.append`) |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]`; also, as a warning, RxSwift `subscribe(onNext:)`/`bind`/`drive` + `.disposed(by:)` into a bag on `self`, and SwiftSignalKit `start(next:)` kept in a disposable on `self` (finite sources stay silent) |
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
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()` |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
capture pipeline as closures.

† upgraded to **error** when the only release call sits in `deinit` (or the
task handle is stored on `self`) — the release is unreachable by construction.

‡ the owned-child path reports a **warning**: a child may clear its callback
after firing, which the owner's source cannot show.

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

## Using it as a pull-request gate

The corpus is always **everything**; only the *report* is scoped. Passing a
pull request's changed files as the input produces a different and wrong
answer, because these are whole-program analyses — `mutual-strong-properties` walks an ownership graph built from every type in the corpus.

```sh
git diff --name-only origin/main... -- '*.swift' > changed.txt
arcleak analyze . --only-from changed.txt --baseline .arcleak-baseline.json --strict
```

`--only` (repeatable) and `--only-from <file|->` scope the report. Findings
outside the scope are kept on `outOfScope` and counted in the summary, so a
scoped run can never be mistaken for a clean one. An empty scope reports
nothing — a pull request that changed no Swift is not a licence to report the
whole repository.

### Fingerprints are portable by default

`Finding.fingerprint` — what `--baseline` matches and what SARIF exports as
`partialFingerprints` — hashes the path **relative to the repository root**,
found by walking up for `.git` (outside a repository, the path as given). So a
baseline committed to the repository matches on any machine, whether the corpus
was named as a directory or as an explicit file list, and wherever the checkout
lives. `--baseline` and `--write-baseline` always use this fingerprint, so a
baseline does not depend on `--relative-to`.

`--relative-to <dir>` changes the paths that are *displayed*, and re-anchors the
`fingerprintPath` and `fingerprint` fields of `--format json` and the SARIF
`partialFingerprints` to that directory (from the repository root, that is the
same anchor). Do not compare those printed fingerprints with a baseline written
without the flag. SARIF uris must be repository-relative for code scanning to
link them, so pass it when uploading SARIF.

### SARIF locations

Every `artifactLocation.uri` in `--format sarif` is an RFC 3986 URI
reference, in one of two forms:

- **Relative**, when `--relative-to <dir>` is given, the file lies inside
  `<dir>`, and its path below `<dir>` is made only of `A–Z a–z 0–9`,
  `- . _ ~ ! $ & ' ( ) * + , = @` and `/`: the uri is that path, unescaped
  (`Sources/App/Box.swift`), with `"uriBaseId": "SRCROOT"`. The run's
  `originalUriBaseIds.SRCROOT.uri` is `<dir>` as a `file://` URI ending in `/`.
- **Absolute** otherwise: `file://` and the absolute path, every other byte
  percent-encoded as UTF-8 (`file:///Users/me/My%20Repo/Sources/Box%231.swift`),
  with no `uriBaseId`. Without `--relative-to`, every location takes this form.

Related locations and degraded-file notes follow the same rules. Paths are
canonical — absolute, symlinks resolved, and on macOS without `/private`
(`/var/folders/…`, `/tmp/…`) — whichever spelling of `<dir>` or of the
analyzed paths the command line used: through a symlink, or with `/private`.

A relative uri is never percent-encoded, so a reader that takes it as a plain
path still finds the file. A path that would need escapes — a space, a `#`,
any non-ASCII letter — is written as an absolute `file://` URI instead, which
every reader decodes. Those uris name the checkout, so they are the one part
of a `--relative-to` report that depends on where the repository lives;
GitHub code scanning converts absolute uris under the checkout directory to
relative ones.

SARIF columns count UTF-16 code units, and the run says so
(`"columnKind": "utf16CodeUnits"`: SARIF requires a run with results to
declare its unit, and this is the one consumers assume and editors index
lines in); a byte-order mark does not count. The `xcode` and `json` formats
keep swift-syntax's 1-based UTF-8 byte columns, the unit compilers print and
the one fingerprints hash.

### Scope-file hygiene

Scope lines tolerate CRLF endings and strip git's simple C-quoting, but paths
with non-ASCII bytes come out of `git diff --name-only` octal-escaped
(`"So\303\251.swift"`), which no unquoting here decodes. Set
`git config core.quotepath false` in the CI checkout so `git diff` emits raw
paths — one line, and every filename matches. When a non-empty scope matches no
analyzed file, arcleak prints a warning to stderr rather than silently
reporting nothing.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | the gate passed: no error-severity finding, so warnings and notes alone pass; with `--strict`, no warning or error. Also after `--write-baseline` and `--fix` |
| `1` | the gate failed on findings: an error-severity finding, or with `--strict` any warning or error — and nothing else |
| `64` | usage error: a bad argument, a path that does not exist, an unreadable `--only-from` file, or `--write-baseline` combined with `--only`/`--only-from` |
| `70` | nothing was analyzed: every file was skipped, and the report on stdout says which and why; or the run failed or was cancelled, and stdout is empty |
| `74` | a file could not be written: a `--fix` result (files written before it keep their fixes), or the `--stamp` of a run that passed |
| `78` | invalid configuration, or a missing, malformed or unwritable baseline |

`1` means findings *only*, so a step that posts a review comment on `1` will
not fire on a typo in the config file. Warnings are always reported, but only
`--strict` makes them fail the gate, and a note never does. A cancelled run reports **no** findings
and exits `70` rather than looking clean: a whole-program analysis over a
partial corpus does not report less, it reports wrongly.

When every file is skipped (unreadable, not UTF-8, or over the 10 MiB cap),
arcleak still prints the report in the requested format — one
`arcleak/degraded-file` note per file in SARIF, whose invocation records
`"executionSuccessful": false` with an error notification — and then exits
`70`. A caller tells the two `70`s apart by standard output: a report there
means nothing could be analyzed; empty means the run itself failed.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax

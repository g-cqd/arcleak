# Rules

arcleak looks for three families of memory bugs:

- **Retain cycles**: closures stored on `self` that capture `self` strongly, Combine `sink` and `assign(to:on:)` cancellables
  stored on `self`, non-terminating `Task`s whose handle lives on `self`.
- **Anchor leaks**: immortal framework objects that keep yours alive: repeating `Timer` and `CADisplayLink` targets and blocks,
  block-based `NotificationCenter` observers, `URLSession` delegates. Cleanup that exists only in `deinit` is a *definite* leak,
  because `deinit` cannot run while the anchor holds `self`.
- **Premature releases**: the inverse bug. Lifetime tokens (`AnyCancellable`, `NSKeyValueObservation`, observer handles) that are
  discarded, or bound to storage that dies at scope end, silently stop the work they own.

## What it leaves alone

Transient escapes (completion handlers, finite `Task`s), non-escaping closures, value-type `self` (SwiftUI bodies), the
same-lifetime `[unowned self]` pattern, sinks over finite pipelines, SwiftData `@Model` relationships, and tokens returned by a
function. A `Task` stored on `self` and cancelled only in `deinit` is the exception.

## How sure each rule is

A leak oracle (`Scripts/run-leak-oracle.sh`) rebuilds the retention contract of the original anchor and cycle rules and checks
it with `leaks -atExit` and deinit canaries on macOS. It does not cover `webview-script-handler-cycle`,
`kvo-observation-self-cycle`, `continuation-overwrite`, the RxSwift and SwiftSignalKit forms of `combine-sink-self-cycle`, closures
on an owned child, or the `sec-*` rules. Those rest on documented behaviour, cited in each rule's explanation.

## The rules

`arcleak rules` lists the rules with their severities, and `arcleak rules <id>` prints one rule's retention contract and fix.

| id | default | detects |
|---|---|---|
| `stored-closure-strong-self` | error‡ | closure stored on `self` (property, `lazy` initializer, member collection) capturing `self` strongly; also one level down, on a child `self` owns through a strong stored property, class or struct (`self.toolbar.onTap = { self… }`, `.append`) |
| `combine-sink-self-cycle` | error | strong-`self` `sink` whose `AnyCancellable` is stored on `self` — including `self` captured only to feed a nested closure's `[weak self]`; also, as a warning, RxSwift `subscribe(onNext:)`/`bind`/`drive` + `.disposed(by:)` into a bag on `self`, and SwiftSignalKit `start(next:)` kept in a disposable on `self` (finite sources stay silent) |
| `combine-assign-self-cycle` | error | `assign(to:on: self)` with the cancellable stored on `self` |
| `timer-retains-self` | warning† | repeating `Timer`/`CADisplayLink` retaining `self` with no reachable `invalidate()` |
| `notification-observer-leak` | warning† | strong-`self` block observer; the center holds block and token until removal |
| `task-nonterminating-self` | warning† | `while true`/`for await` `Task` capturing `self` strongly; also a `Task` stored on `self` whose body awaits, captures `self` strongly and is cancelled only in `deinit` (warning) |
| `unstored-lifetime-token` | warning | lifetime token discarded — from framework APIs or same-file functions whose return type is a token |
| `token-stored-in-local` | warning | token bound to storage that dies at scope end, or to a local captured by an escaping closure (never removed → unbounded growth) |
| `mutual-strong-properties` | warning | cross-file ownership-graph cycle: strong stored properties whose types point at each other, reported with the retention path |
| `urlsession-delegate-leak` | warning† | `URLSession(configuration:delegate: self, …)` with no reachable invalidation |
| `dispatch-source-cycle` | error | dispatch source stored on `self` whose handler captures `self` strongly, no reachable `cancel()` |
| `unowned-outlives-owner` | warning | `[unowned self]` in an anchor-held closure — traps if `self` deallocates first |
| `webview-script-handler-cycle` | warning† | `userContentController.add(self, name:)` (or `add(_:contentWorld:name:)`) with no reachable `removeScriptMessageHandler(forName:)` or `removeAllScriptMessageHandlers()`; the deinit-only **error** needs the `add` receiver to start at a strong stored `WKWebView`, `WKWebViewConfiguration` or `WKUserContentController` property of the type; a parameter or local receiver is at most an "observed" warning, and a type that keeps none of them is silent on a deinit-only removal |
| `kvo-observation-self-cycle` | warning | `self.<obs> = <x>.observe(\.keyPath) { … self … }` (any observed object `<x>`) whose change handler captures `self` strongly, with no reachable `invalidate()` in the type (any `invalidate()` counts, a Timer's included). `invalidate()` alone does not release the change handler: also set the observation to nil |
| `continuation-overwrite` | warning | `member = continuation` in a `with(Checked\|Unsafe)(Throwing)?Continuation` closure, with no condition before it in the closure or the method and nothing that checks, resumes or clears the stored member first. A second call before the first resumes drops the first caller's continuation, which then never resumes. A `guard`, an `if` or any condition before the store, a continuation kept under a key or appended, and a computed member are left alone. |
| `dead-weak-capture` | warning, opt-in | `[weak self]` whose body never uses `self` |
| `delegate-strong-property` | warning, opt-in | strong stored property named/typed like a delegate |
| `sec-session-in-cycle` | opt-in tag | security (CWE-401): adds a note to each cycle finding on a type that keeps a `WKWebView`, `LAContext`, `ASWebAuthenticationSession` or a `URLSession` with a delegate; no finding of its own. `@al:disable` has no effect on it, since it emits no findings to suppress: turn it off in `.arcleak.json` |
| `sec-cleanup-in-unreachable-deinit` | note, opt-in | security (CWE-401, CWE-226): a `deinit` that wipes bytes, invalidates a session, closes a handle or cancels work, in a type that a cycle or anchor finding on that type may keep alive |

Security pack: the `sec-` rules ship disabled and are enabled one by one in `.arcleak.json`, like the other opt-in rules
(`{"rules": {"sec-cleanup-in-unreachable-deinit": {"enabled": true}, "sec-session-in-cycle": {"enabled": true}}}`). In SARIF
output their rule descriptors carry `properties.tags`: `security`, and each CWE id in two forms, `external/cwe/cwe-401` (the
form CodeQL queries use) and `CWE-401`.

Bound method references (`handler = self.method`, `sink(receiveValue:
handle)`) and self-referencing local functions passed as values feed the same
capture pipeline as closures.

† upgraded to **error** when the only release call sits in `deinit` (or a
non-terminating task's handle is stored on `self`) — the release is
unreachable by construction.

‡ the owned-child path reports a **warning**: a child may clear its callback
after firing, which the owner's source cannot show.

## Limits

Cross-file cycle detection covers the analyzed corpus: every file passed in
one run. Types, weak-ness, and class-ness declared in other modules and the
SDK are outside it by default — the opt-in macOS `--index-store` backend
resolves class-ness for those (see [Cross-module types](index-store.md)); release-call reachability across
files remains corpus-only.
`mutual-strong-properties` is type-level: an SCC proves the types *can*
cycle; verify instance ownership before restructuring. Analysis is of
written source — macro-generated storage is invisible (SwiftData `@Model` is
special-cased).

Two indirection gaps are known and deliberate rather than silently wrong.
Custom `.sink`/`.assign` **wrappers** hide the API shape from the matcher —
opt in with a `sinkWrapper` contract (see [Configuration](configuration.md#custom-retention-contracts)) so arcleak analyzes the wrapper's
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

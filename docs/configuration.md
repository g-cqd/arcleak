# Configuration

arcleak reads `.arcleak.json`, or an `"arcleak"` section of the shared `.swift-analyzers.json`
([how files are found and merged](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#configuration)).

```json
{
  "rules": {
    "task-nonterminating-self": { "severity": "error" },
    "token-stored-in-local": { "enabled": false }
  },
  "exclude": ["Generated/", "Tests/Fixtures/"]
}
```

An unknown rule id is an error. The definite-leak upgrade (cleanup reachable only from an unreachable `deinit`) is always an
`error`; use a directive if it is intentional.

## Custom retention contracts

arcleak matches literal API shapes (`.sink`, `.assign`, `Timer`). A helper that wraps them, such as a `React.to` or a `bind`,
hides the shape. Declare the wrapper in `contracts` and arcleak sees through it. Without a contract it stays silent rather than
guess, and a malformed contract is an error.

```json
{
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

| Field | |
| --- | --- |
| `callee` | The method name (`to` in `React.to(…)`). Required. |
| `base` | The receiver, for a static call. |
| `requiredLabels` | Labels that must all be present to match. |
| `tokenName` | The name shown in the diagnostic. |
| `template` | One of the four below. |

| Template | The call is |
| --- | --- |
| `tokenProducer` | a call that returns a lifetime token that must be owned. A discarded or scope-local token is flagged like a dropped `AnyCancellable`. |
| `sinkWrapper` | a wrapper over `.sink` or `.assign`. The token feeds the premature-release rules, and its closure is checked for a strong `self`. A token stored on `self` is reported as `combine-sink-self-cycle`, as a warning, because completion is unknown. |
| `disposeBag` | an RxSwift-style subscription whose Disposable goes into a bag on `self` through `.disposed(by:)` or `addDisposableTo(_:)`. A warning; finite sources (`Single`, `Completable`, `Maybe`, `just`, `take(1)`, `first()`) stay silent. Built in for `subscribe`, `bind` and `drive`. |
| `signalDisposable` | a SwiftSignalKit-style subscription whose Disposable is passed to `self.<disposable>.set(_:)` or `.add(_:)`, or assigned to a member of `self`. Same report and finiteness rules. Built in for `start(next:)`. |

The two reactive templates feed only the cycle rule: a dropped Disposable does not end its subscription.

With the contract above, `token = React.to(.willResignActive) { _ in self.disconnect() }` is flagged, and the same call with
`[weak self]` is not.

## Choosing a setup

- **CI gate: the defaults.** Syntax-only analysis is high precision and reports nothing it cannot prove.
- **Wrapped Combine or Rx APIs:** add a contract for each wrapper.
- **Cycles through other modules:** add [`--index-store`](index-store.md) on macOS.
- **Silence is not proof.** A wrapper arcleak does not know, a cycle through an unresolved module, or macro-generated storage can
  hide a leak. Use Instruments or `leaks` for ground truth.

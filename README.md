# arcleak

Finds memory leaks in Swift source before they ship: retain cycles, objects kept alive by the system, and tokens released too
early. It reads source with [swift-syntax](https://github.com/swiftlang/swift-syntax), so it needs no build, no index and no
project file.

```swift
final class Poller {
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.poll()  // timer-retains-self: the run loop keeps `self` alive
        }
    }
}
```

## What it finds

- **Retain cycles:** closures, Combine subscriptions and tasks that are stored on `self` and capture `self` strongly.
- **Anchor leaks:** repeating timers, notification observers and `URLSession` delegates that keep your object alive, so cleanup
  in `deinit` never runs.
- **Premature releases:** `AnyCancellable`s and observation tokens that are discarded or die at scope end, silently stopping
  their work.

It reports only what it can show, so silence means "no provable cycle in the code it can see", not "no cycles". The
[rules](docs/rules.md) say what each one covers and what it leaves alone.

## Install

Download an archive from the [releases](https://github.com/g-cqd/arcleak/releases), or build with Swift 6.4 on macOS 15 or later,
or Linux:

```sh
swift build -c release
cp .build/release/arcleak /usr/local/bin/
```

## Use

```sh
arcleak analyze Sources           # diagnostics in Xcode's format
arcleak analyze --strict Sources  # warnings fail too
arcleak analyze --format sarif .  # for GitHub code scanning
arcleak rules                     # the rules, and how to accept a finding
```

It also runs as a SwiftPM build-tool plugin, as a GitHub Action, and as an LSP server.

## Learn more

- [User guide](docs/README.md): getting started, rules, configuration, CI, reports.
- [Development](development/): how arcleak is built and released.

arcleak is one of a family of analyzers with the same options and reports:
[deadwood](https://github.com/g-cqd/deadwood) (unused code), [dolly](https://github.com/g-cqd/dolly) (duplicated code),
[fcheck](https://github.com/g-cqd/fcheck) and [modeler](https://github.com/g-cqd/modeler).

[MIT](LICENSE)

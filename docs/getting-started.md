# Getting started

arcleak reads Swift source. It needs no build, no index and no project file.

## Install

Download an archive from the [releases](https://github.com/g-cqd/arcleak/releases) (macOS arm64, Linux x86_64), or build with a
Swift 6.4 toolchain on macOS 15 or later, or Linux:

```sh
git clone https://github.com/g-cqd/arcleak.git && cd arcleak
swift build -c release
cp .build/release/arcleak /usr/local/bin/
```

## Run it

```sh
arcleak analyze Sources           # Xcode-style diagnostics; exit 1 on errors
arcleak analyze --format json .   # also: --format sarif
arcleak analyze --strict Sources  # warnings fail too; notes never do
arcleak analyze --fix Sources     # apply [weak self] fix-its (--fix-dry-run previews)
arcleak rules timer-retains-self  # one rule's retention contract and fix
arcleak lsp                       # LSP server on stdio, with an "accept" quick fix
```

Exit `0` means the gate passed and `1` means findings. `64`, `70`, `74` and `78` mean the run itself broke
([exit codes](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#exit-codes)).

## Project context

Directories are searched for Xcode projects, package manifests, Info.plists, storyboards and xibs as well as Swift files. From
them arcleak learns:

- **Platforms.** `#if os(...)` follows the project's platforms, else the host's. The `platforms` setting overrides both.
- **Debug or release.** Debug is analyzed, and a finding in `#if DEBUG` code says so. `"debugBuild": false` switches.
- **Previews and generated files.** Findings there are withheld and listed with the suppressed ones.
- **Test code.** A finding in a test file says so.
- **Classes the system creates** (principal classes, scene delegates, storyboard classes) live as long as the process, so their
  findings are notes.

## Adopting it on existing code

```sh
arcleak analyze Sources --write-baseline .arcleak-baseline.json
arcleak analyze Sources --baseline .arcleak-baseline.json  # only new findings fail
```

Baselines match on position; see [baselines](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#baselines-and-fingerprints).

## Accepting a finding

`@al:` and `@arcleak:` are the same directive. `accept` records an intentional reference and its reason; it covers the flagged
line and the next:

```swift
// @al:accept -- owner tears this down in shutdown()
onTick = { self.tick() }

// @al:accept:this timer-retains-self -- invalidated by the scene lifecycle
// @al:accept:next stored-closure-strong-self
// @al:disable combine-sink-self-cycle
// @al:enable combine-sink-self-cycle
```

Accepted findings stay in the JSON report, with their reasons.

# Using arcleak in builds and in CI

## In every build

A SwiftPM build-tool plugin shows diagnostics inline, and error findings fail the build:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/g-cqd/arcleak.git", from: "0.17.0")
],
targets: [
    .target(
        name: "App",
        plugins: [.plugin(name: "ArcLeakBuildToolPlugin", package: "arcleak")]
    )
]
```

`swift package arcleak [paths…]` runs it on demand. In an Xcode project, a run-script phase does the same:
`arcleak analyze "${SRCROOT}/Sources"`.

The plugin analyzes one target per run, so a `mutual-strong-properties` cycle across targets is invisible to it. Treat the
whole-repository CI gate as the authority.

## As a pull-request gate

Analyze the whole repository and scope the report to the change ([why](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#scoping-a-report-to-some-files)):

```sh
git diff --name-only origin/main... -- '*.swift' > changed.txt
arcleak analyze . --only-from changed.txt --baseline .arcleak-baseline.json --strict
```

For code scanning, add `--format sarif --relative-to .` and upload the result ([SARIF](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#sarif)). A composite GitHub Action
(`action.yml`) builds arcleak, analyzes, and uploads the SARIF.

For a gate on new findings only, write a baseline on the base branch and read it on the pull request:

```sh
arcleak analyze . --write-baseline base.json                                   # on the base branch
arcleak analyze . --baseline base.json --only-from changed.txt                 # on the pull request
```

An edit above an old finding in a changed file brings it back, because the fingerprint includes the position.

## In the editor

`arcleak lsp` serves diagnostics and an "accept" quick fix over stdio.

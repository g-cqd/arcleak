# Command line and reports

The options, exit codes and report format are shared with the other analyzers; see
[how the analyzers behave](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md). This page lists what arcleak adds.

## Options

| Option | |
| --- | --- |
| `--format xcode\|json\|sarif` | The output format (default `xcode`). |
| `--only PATH`, `--only-from FILE` | Report only these files; the whole corpus is still analyzed. |
| `--relative-to DIR` | Print paths relative to `DIR`. |
| `--baseline FILE`, `--write-baseline FILE` | Drop accepted findings; record the current ones. |
| `--report-new-since BASELINE` | With `--only`, also report findings outside it that the baseline does not hold. |
| `--config FILE` | Read this configuration file. |
| `--cache-path DIR`, `--no-cache` | Move or disable the [cache](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#the-facts-cache). |
| `--strict` | Warnings fail the gate too. |
| `--include-regions`, `--exclude-regions` | `preview`, `debug`, `test`, `mock`, `generated`, `script` or `all`. |
| `--exclude-path PATTERN` | Skip matching paths; repeatable. |
| `--rules IDS` | Run only these rules (comma-separated). |
| `--fix`, `--fix-dry-run` | Apply, or preview, `[weak self]` fix-its. |
| `--quiet`, `--verbose`, `--timings` | Say less or more on stderr; time each phase. |
| `--index-store`, `--index-store-path`, `--index-store-build` | [Cross-module types](index-store.md). |
| `--experimental-embedding-rank`, `--embedding-bundle` | [Grouping by similarity](embeddings.md). |

Exit `74` also covers a `--fix` result or a `--stamp` that could not be written.

## The JSON report

The shared keys are in [the contract](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#the-json-report). A finding adds:

| Key | |
| --- | --- |
| `related` | The other locations of the finding (`[{path, line, column}]`), such as the other links of a cycle. Omitted when empty. |
| `fingerprintPath` | The path the fingerprint hashes, set inside a git repository and under `--relative-to`. |

## Stability

The `schemaVersion` is `1`. Within it, `arcleak analyze`, the options above, the exit codes and the JSON fields do not change
incompatibly; adding an option or a field is not a breaking change. Not covered: `--define`, `--stamp`, `--experimental-*`, the
`rules` and `lsp` commands, and the `ArcLeakCore` library.

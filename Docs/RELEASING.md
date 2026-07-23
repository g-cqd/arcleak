# Releasing arcleak

Pushing a tag `vX.Y.Z` runs `.github/workflows/release.yml`: it builds
release binaries for Linux (static stdlib, x86_64) and macOS (arm64),
verifies `arcleak --version` matches the tag, and publishes a GitHub release
with the archives, SHA-256 checksums, and generated notes. Every CI run on
`main` also uploads per-commit binaries as workflow artifacts (14-day
retention).

## Checklist before tagging

1. `Scripts/ci-local.sh` green on the pinned toolchain (`swiftly run`).
2. Analyze 2-3 large real Swift apps and investigate any new finding class.
3. Bump `ToolInfo.version` (single source of truth: CLI `--version`, SARIF
   driver, baseline headers, cache invalidation key; the release workflow
   fails on a tag/version mismatch).
4. Update the README rules table if the catalog changed.
5. `swift package --package-path Benchmarks --allow-writing-to-package-directory benchmark baseline update local`
   on quiet hardware; commit the baseline.
6. Tag `vX.Y.Z` and push the tag.

## Homebrew formula template

```ruby
class Arcleak < Formula
  desc "Static ARC analysis for Swift: retain cycles, anchor leaks, premature releases"
  homepage "https://github.com/g-cqd/arcleak"
  url "https://github.com/g-cqd/arcleak/archive/refs/tags/vX.Y.Z.tar.gz"
  sha256 "…"
  license "MIT"

  depends_on xcode: ["16.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/arcleak"
  end

  test do
    (testpath/"t.swift").write "final class A { var h: (() -> Void)?; func f() { h = { self.f() } } }"
    assert_match "stored-closure-strong-self", shell_output("#{bin}/arcleak analyze #{testpath} --no-cache 2>&1", 1)
  end
end
```

## GitHub Action

Consumers reference the committed `action.yml`:

```yaml
- uses: g-cqd/arcleak@vX.Y.Z
  with:
    paths: Sources
```

# Releasing arcleak

Publishing is deliberately manual — nothing in the repo pushes anywhere.

## Checklist

1. `Scripts/ci-local.sh` green on the release toolchain.
2. Re-run the dogfood corpus (`/tmp/arcleak-dogfood` pattern in DESIGN.md) and
   record counts in DESIGN.md; investigate any new finding class before
   tagging.
3. Bump `ToolInfo.version` (single source of truth: CLI `--version`, SARIF
   driver, baseline headers, cache invalidation key all follow it).
4. Update the README rules table if the catalog changed.
5. `swift package --package-path Benchmarks --allow-writing-to-package-directory benchmark baseline update local`
   on quiet hardware; commit the baseline.
6. Tag `vX.Y.Z`; GitHub release notes from the DESIGN.md status entries since
   the last tag.

## Homebrew formula template

```ruby
class Arcleak < Formula
  desc "Static ARC analysis for Swift: retain cycles, anchor leaks, premature releases"
  homepage "https://github.com/OWNER/arcleak"
  url "https://github.com/OWNER/arcleak/archive/refs/tags/vX.Y.Z.tar.gz"
  sha256 "…"
  license "MIT" # decide before first tag

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
- uses: OWNER/arcleak@vX.Y.Z
  with:
    paths: Sources
```

# ADJSON adoption evaluation — arcleak FactsCache

Decision record for replacing Foundation's `JSONEncoder`/`JSONDecoder` with
**ADJSON** (g-cqd's fast JSON) on arcleak's facts-cache hot path. Every number
here was measured on this machine with the harness committed on `main`
(`Benchmarks/`), so the result is reproducible.

**Iron law:** if a cell is a number, it was measured — no hand-waving.

## TL;DR verdict — **ADOPT** (default-on cache)

> ADJSON's reflection-free fast path makes the internal, version-gated FactsCache
> **decode 4x** (16 -> 4 ms) and **encode 6x** (18 -> 3 ms) faster, quartering
> allocations, and **flips the warm cache from slower-than-cold to clearly
> faster**: end-to-end **warm / cold falls from 1.19x to 0.53x** (coder alone),
> and to **~0.3x** with a one-line persist-skip guard. At the CLI, warm drops
> from **73 ms (1.14x of cold) to 40 ms (0.64x of cold)**. Correctness is
> byte-perfect (real 434-file payload round-trips value-equal to Foundation; the
> cache round-trip is byte-stable; fail-open + version gate intact). ADJSON +
> ADFoundation compile and link on Linux (103 tests green). The cache was already
> **default-on** in arcleak; this makes keeping it on unambiguously worth it. Only
> the internal FactsCache moves to ADJSON — report/SARIF/baseline stay on
> Foundation (they hash encoded bytes across runs).

## Why the facts cache is the adoption target

- `Sources/ArcLeakCore/Cache/FactsCache.swift` round-trips a `[String: Entry]`
  payload (per-file ARC facts: stored properties, stored closures, API calls,
  task spawns, release sites, directives) through JSON. It is **internal +
  tool-version-gated** (`Payload.version == ToolInfo.version` or the whole cache
  is discarded) and **fail-open** (any decode error -> empty cache). ADJSON's
  known byte-level differences vs Foundation — `Double` `2.0` vs `2`, and `/`
  left unescaped vs Foundation's `\/` — are **harmless here**: nothing outside
  this tool version ever reads these bytes, and both decode to the same values.
- The cache is **default-on** (`--no-cache` disables it). The question is whether
  a warm (cache-hit) run is actually *faster* than a cold re-parse, so the
  default earns its keep. With Foundation it was **not** — warm lost to cold.

## Environment

| | |
|---|---|
| Machine | Apple Silicon MBP23, 10 cores, 16 GB (macOS 27 / Darwin 27) |
| Toolchain | `swiftly` default — Swift 6.5-dev snapshot `2026-07-11-a` |
| Build/test | `swiftly run swift build` / `swiftly run swift test` |
| arcleak | branch `main`, base v0.3.1 |
| Corpus | `Luce/Luce` — **434** `.swift` files |
| Payload | Foundation **668,202 B** / ADJSON **659,080 B**, **434** entries |
| Framework | ordo-one `package-benchmark` 1.27 (`Benchmarks/`), release, p50 wall + `mallocCountTotal` |

**arcleak's facts are lighter than deadwood's** (a declaration/reference graph):
the payload is ~652 KiB here vs deadwood's 26.6 MiB, ~40x smaller — so the
absolute coder times are small and the win was expected to be smaller. It is
still decisive, because Foundation's coder round-trip (34 ms) is large next to
the 42 ms parallel parse it competes with.

## Methodology

- **Real payload.** `arcleak analyze Luce/Luce --cache-path facts.json` populates
  a real cache over 434 files. The facts.json is regenerated with each coder, so
  decode always parses bytes its own encoder produced (self-consistent).
- **Isolated coder timing.** A `@_spi(Benchmarks)` seam (`FactsCacheBenchmark`)
  exposes `decode(Data)` / `encode(Payload)` routed through the *exact*
  `encodePayload`/`decodePayload` functions `load`/`persist` use, so the swap is
  measured on the production path.
- **End-to-end.** `analyze cold` = `analyze(files:)` (no cache, re-parse all
  434). `analyze warm` = `analyze(files:cacheURL:)` after priming (read + decode,
  skip parse, re-run rules, persist). Warm-beats-cold is the payoff.
- p50 over >=30 (e2e) / 100 (coder) samples; `mallocCountTotal` via the
  package-benchmark interposer. CLI wall is p50 over 6 release-binary runs.

## Before / after — the deliverable

p50 wall + `mallocCountTotal`, package-benchmark, release, real 434-file payload.

| Metric | Foundation | ADJSON fast | Δ | speedup | malloc F -> A |
|---|---:|---:|---:|---:|---:|
| factscache **decode** | 16 ms | **4 ms** | -12 ms | **4.0x** | 70K -> 10K (-86%) |
| factscache **encode** | 18 ms | **3 ms** | -15 ms | **6.0x** | 52K -> 8K (-85%) |
| coder **round-trip** | 34 ms | **7 ms** | -27 ms | **4.9x** | |
| analyze **cold** (e2e) | 42 ms | 42 ms | 0 | 1.0x | 419K = (coder-independent) |
| analyze **warm** (e2e) | 50 ms | **21 ms** | -29 ms | **2.4x** | 134K -> 30K (-78%) |
| analyze **warm** (+ persist-skip guard) | — | **12 ms** | -38 ms | **4.2x** | -> 20K |
| **payload bytes** | 668,202 | 659,080 | -9,122 | 0.99x | (unescaped `/`) |
| **warm / cold** | **1.19x** | **0.53x** -> **0.29x** | | flips <1 | |

### CLI end-to-end (release binary, wall p50)

| | COLD (`--no-cache`) | WARM (cache hit) | warm / cold |
|---|---:|---:|---:|
| **Foundation** | 64 ms | 73 ms | **1.14x** (warm loses) |
| **ADJSON** (coder only) | 58 ms | 45 ms | 0.77x |
| **ADJSON + persist-skip guard** | 62 ms | **40 ms** | **0.64x** (warm wins) |

## The decisive pair — WARM vs COLD

Foundation's warm run **loses to cold** (1.19x in-process, 1.14x at the CLI): it
pays decode + encode (34 ms) to skip a parse that, run in parallel across 10
cores, costs less. ADJSON's fast path drops the round-trip to **7 ms**, so:

- **The coder alone flips it:** warm 50 -> 21 ms, warm/cold 1.19x -> **0.53x**.
- **The persist-skip guard finishes it:** on an all-hits run with nothing to
  prune, re-writing the cache changes nothing the next run reads (entries are
  validated by source fingerprint, not by the cache's own bytes), so the guard
  skips the redundant re-encode + write. Warm -> **12 ms in-process / 40 ms CLI**,
  warm/cold -> **~0.3x / 0.64x**.

So the cache is now unambiguously worth keeping **default-on**: a warm run is
~2-3x *faster* than re-parsing, where before it was ~1.2x slower.

## Correctness

- **All 8 `CacheTests` green:** hit/miss, edited-file invalidation, prune-absent,
  corrupt -> fail-open, tool-version-mismatch discard, plus two new tests —
  `realisticPayloadRoundTripsByteStableAndLossless` (a payload exercising every
  fact type and enum, incl. `APICallFact` + the associated-value enums a live
  corpus rarely produces, round-trips byte-identically and preserves each value)
  and `allHitsWarmRunSkipsRepersist` (the guard leaves the cache untouched on an
  all-hits run and still persists on a miss/prune).
- **Real 434-file payload** round-trips **value-equal** to the Foundation cache
  (canonical compare), and every whole-suite test (110 tests) is green.
- **Byte-stable round-trip.** Sets encode as **sorted** arrays (the previous
  Foundation coder sorted only dictionary keys, never Set elements), and the
  top-level `entries` map is emitted sorted, so persist -> load -> re-persist is
  byte-identical — the cache is now *more* reproducible than under Foundation.
- **Fail-open + version gate intact;** a corrupt cache decodes to empty and is
  overwritten. `ToolInfo.version` bumped to **0.4.0**, so any older on-disk cache
  is discarded rather than mis-decoded.
- **Leak oracle unchanged by ADJSON.** The `leak-oracle` target has no
  ArcLeakCore dependency (`Sources/leak-oracle` is byte-identical to baseline),
  so the ADJSON change cannot affect it. On this toolchain (Swift 6.5-dev
  snapshot / Darwin 27) it runs **18/19** — `leaks` does not flag the
  `mutual_strong_properties` cycle — and that one miss **reproduces identically on
  the pre-ADJSON baseline** (a `leaks`/optimizer artifact, not a cache regression).

## What moved, and what did not

- **Moved to ADJSON:** only `FactsCache` (internal, version-gated, fail-open).
  `@JSONCodable` on the 9 payload structs; hand-written fast conformances for the
  String-raw enum leaves (`ReferenceStrength`, `ReleaseSite.Kind`,
  `APICallFact.UpstreamFiniteness`, `RuleID`) and for sorted `Set`s
  (`FactsFastCoding.swift`); the associated-value enums (`SelfCaptureKind`,
  `ResultConsumption`, `APICallFact.Kind`, `SuppressionDirective.Kind`) ride
  ADJSON's generic Codable bridge (O(n) with the pinned CoW fix; rare in a real
  corpus). Entry/Payload hand-written so `Payload` sorts the top-level `entries`.
- **Stayed on Foundation:** report, SARIF, and baseline output — they serialize
  bytes compared across runs and tools, and ADJSON's number/slash formatting
  differs. The fingerprint (FNV-1a over source bytes) is unchanged.

## Dependency cost

Adopting the `ADJSON` product pulls **4 net-new packages**: `ADJSON` +
`ADFoundation` (g-cqd, on unpinned `main` — **revision-pinned** in
`Package.resolved` to `1d7fb25` / `062d93c`; `1d7fb25` carries the
`JSONWriter(adopting:)` CoW fix the fast encode path needs), plus
`swift-collections` and `swift-system`. ADFoundation ships a **C SIMD kernel**
target (`CADFKernels`) — a native surface to trust. swift-syntax is already an
arcleak dependency and is shared.

- **Binary size** (`.build/release/arcleak`): Foundation **24,285,080 B** ->
  ADJSON **26,826,776 B** (**+2,541,696 B, +10.5%**) from statically linking
  ADJSON + ADFoundation + OrderedCollections.
- **Clean build time** (deps pre-resolved, debug; swift-syntax + IndexStoreDB
  compile in both, so the delta isolates ADJSON's added targets): Foundation
  **67.9 s** -> ADJSON **87.1 s** (**+19.2 s, +28%**). Smaller than deadwood's
  +136% because arcleak's IndexStoreDB-heavy baseline is already large.
- **Linux — PASS.** `swift build --build-tests && swift test` on
  `swiftlang/swift:nightly-6.4.x-jammy`: **103 tests in 19 suites passed** (7
  macOS-only tests — IndexStoreDB, SILGen, embedding — gate out). ADJSON +
  ADFoundation (+ the `CADFKernels` C SIMD target, OrderedCollections,
  SystemPackage) build and link; the macOS-only IndexStoreDB stays
  platform-gated. Not a Linux disqualifier.

## Verdict — **ADOPT**

ADJSON is materially faster on the coder (decode 4x, encode 6x, allocations
quartered) and — the point of the evaluation — **turns the default-on facts
cache from a slight loss into a clear win**: warm/cold 1.19x -> 0.29x in-process,
1.14x -> 0.64x end-to-end. Correctness is byte-perfect and the one real risk in
the family (ADJSON's encoder O(n^2), found by deadwood) is already fixed upstream
and pinned. The +4-package / +binary / +build-time cost buys a cache that is now
genuinely worth shipping on by default. Adopt on `FactsCache`; keep everything
that hashes bytes across tools on Foundation.

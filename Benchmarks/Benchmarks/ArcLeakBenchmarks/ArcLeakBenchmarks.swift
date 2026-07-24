@_spi(Benchmarks) import ArcLeakCore
import Benchmark
import Foundation

private func generatedSource(types: Int) -> String {
    (0..<types).map { index in
        """
        final class C\(index) {
            var next: C\((index + 1) % types)?
            var handler: (() -> Void)?
            func arm() { handler = { [weak self] in _ = self } }
        }
        """
    }.joined(separator: "\n")
}

/// Recursively collect `.swift` files under `root`, skipping build/VCS dirs —
/// the corpus for the warm/cold facts-cache benchmarks.
private func discoverSwift(_ root: String) -> [String] {
    let skip: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
    let manager = FileManager.default
    guard
        let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else { return [] }
    var files: [String] = []
    for case let url as URL in enumerator {
        if skip.contains(url.lastPathComponent) {
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension == "swift" { files.append(url.path) }
    }
    return files.sorted()
}

let benchmarks: @Sendable () -> Void = {
    let small = generatedSource(types: 1_000)
    let ring = generatedSource(types: 20_000)
    let blob = Data(count: 8 * 1024 * 1024)  // 8 MB, exercises the fingerprint path

    Benchmark(
        "extract+rules 1k types",
        configuration: .init(
            metrics: [.cpuTotal, .mallocCountTotal, .peakMemoryResident], maxDuration: .seconds(5))
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Analyzer().analyze(source: small, path: "bench.swift"))
        }
    }

    Benchmark(
        "corpus SCC 20k-type ring",
        configuration: .init(metrics: [.cpuTotal, .peakMemoryResident], maxDuration: .seconds(10))
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Analyzer().analyze(source: ring, path: "ring.swift"))
        }
    }

    Benchmark(
        "fingerprint 8MB",
        configuration: .init(metrics: [.cpuTotal, .mallocCountTotal], maxDuration: .seconds(5))
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(FactsCache.fingerprint(of: blob))
        }
    }

    // MARK: - ADJSON adoption evaluation — FactsCache coder + warm/cold

    // Isolated coder timing on a real facts payload. `ARCLEAK_FACTS_JSON` points
    // at a facts.json produced by `arcleak analyze <corpus> --cache-path`, so the
    // decode always parses bytes its own encoder produced (self-consistent per
    // coder — no Foundation-vs-ADJSON byte skew polluting the number).
    let env = ProcessInfo.processInfo.environment
    if let factsPath = env["ARCLEAK_FACTS_JSON"],
        let data = try? Data(contentsOf: URL(fileURLWithPath: factsPath))
    {

        Benchmark(
            "factscache-decode",
            configuration: .init(
                metrics: [.wallClock, .mallocCountTotal],
                timeUnits: .milliseconds, maxDuration: .seconds(20), maxIterations: 100)
        ) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try FactsCacheBenchmark.decode(data))
            }
        }

        if let payload = try? FactsCacheBenchmark.decode(data) {
            Benchmark(
                "factscache-encode",
                configuration: .init(
                    metrics: [.wallClock, .mallocCountTotal],
                    timeUnits: .milliseconds, maxDuration: .seconds(20), maxIterations: 100)
            ) { benchmark in
                for _ in benchmark.scaledIterations {
                    blackHole(try FactsCacheBenchmark.encode(payload))
                }
            }
        }
    }

    // End-to-end warm (cache hit) vs cold (--no-cache re-parse) over a real
    // corpus. `ARCLEAK_CORPUS` is the source dir; `ARCLEAK_WARM_CACHE` a working
    // cache path pre-primed from `ARCLEAK_FACTS_JSON` in this benchmark's setup.
    if let corpus = env["ARCLEAK_CORPUS"] {
        let files = discoverSwift(corpus)
        if !files.isEmpty {
            Benchmark(
                "analyze-cold",
                configuration: .init(
                    metrics: [.wallClock, .mallocCountTotal],
                    timeUnits: .milliseconds, maxDuration: .seconds(30), maxIterations: 30)
            ) { benchmark in
                for _ in benchmark.scaledIterations {
                    await blackHole(Analyzer().analyze(files: files, cacheURL: nil))
                }
            }

            if let warmPath = env["ARCLEAK_WARM_CACHE"], let factsPath = env["ARCLEAK_FACTS_JSON"] {
                let warmURL = URL(fileURLWithPath: warmPath)
                let factsURL = URL(fileURLWithPath: factsPath)
                Benchmark(
                    "analyze-warm",
                    configuration: .init(
                        metrics: [.wallClock, .mallocCountTotal],
                        timeUnits: .milliseconds, maxDuration: .seconds(30), maxIterations: 30,
                        setup: {
                            // Start each measurement from the pristine primed
                            // cache so a warm run's re-persist can't compound.
                            try? FileManager.default.removeItem(at: warmURL)
                            try FileManager.default.copyItem(at: factsURL, to: warmURL)
                        })
                ) { benchmark in
                    for _ in benchmark.scaledIterations {
                        await blackHole(Analyzer().analyze(files: files, cacheURL: warmURL))
                    }
                }
            }
        }
    }
}

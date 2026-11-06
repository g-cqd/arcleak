@_spi(Benchmarks) import ArcLeakCore
import Benchmark
import CorpusScan
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

/// `count` generated files in a fresh directory, a ring of types across them: the corpus the cache benchmarks read. The
/// directory stays for the process (the benchmark binary), under the temporary directory.
private func writtenCorpus(files count: Int, typesPerFile: Int) -> [String] {
    let directory = FileManager.default.temporaryDirectory.appending(path: "arcleak-bench-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let types = count * typesPerFile
    return (0..<count).compactMap { file in
        let source = (0..<typesPerFile).map { offset -> String in
            let index = file * typesPerFile + offset
            return """
                final class C\(index) {
                    var next: C\((index + 1) % types)?
                    var handler: (() -> Void)?
                    func arm() { handler = { [weak self] in _ = self } }
                }
                """
        }.joined(separator: "\n")
        let url = directory.appending(path: "File\(file).swift")
        return (try? source.write(to: url, atomically: true, encoding: .utf8)).map { url.path }
    }
}

let benchmarks: @Sendable () -> Void = {
    // Instructions and allocations are what a comparison can trust; time on a shared machine is a realism check.
    let counted: [BenchmarkMetric] = [.instructions, .mallocCountTotal, .cpuTotal, .peakMemoryResident]
    // What a comparison with the commit before fails on (swift-ci's benchmark command): 2 % more instructions, 1 % more allocations.
    let tolerances: [BenchmarkMetric: BenchmarkThresholds] = [
        .instructions: BenchmarkThresholds(relative: [.p50: 2.0]),
        .mallocCountTotal: BenchmarkThresholds(relative: [.p50: 1.0]),
    ]
    let small = generatedSource(types: 1_000)
    let ring = generatedSource(types: 20_000)

    Benchmark(
        "extract+rules 1k types",
        configuration: .init(metrics: counted, maxDuration: .seconds(5), thresholds: tolerances)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Analyzer().analyze(source: small, path: "bench.swift"))
        }
    }

    Benchmark(
        "corpus SCC 20k-type ring",
        configuration: .init(metrics: counted, maxDuration: .seconds(10), thresholds: tolerances)
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Analyzer().analyze(source: ring, path: "ring.swift"))
        }
    }

    // The facts cache (analyzerkit's CorpusScanner) over files on disk: cold re-extracts every file, warm decodes every entry.
    // `ARCLEAK_CORPUS` names a real source directory instead of the generated one.
    let env = ProcessInfo.processInfo.environment
    let files = env["ARCLEAK_CORPUS"].map(discoverSwift) ?? writtenCorpus(files: 200, typesPerFile: 25)
    guard !files.isEmpty else { return }
    let workspace = URL(fileURLWithPath: files[0]).deletingLastPathComponent().path
    let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "arcleak-bench-cache-\(UUID().uuidString)")
        .path
    let cache = CacheLocation(root: cacheRoot, workspace: workspace)

    Benchmark(
        "analyze-cold \(files.count) files",
        configuration: .init(metrics: counted, maxDuration: .seconds(30), maxIterations: 30, thresholds: tolerances)
    ) {
        benchmark in
        for _ in benchmark.scaledIterations {
            await blackHole(Analyzer().analyze(files: files, cache: nil))
        }
    }

    Benchmark(
        "analyze-warm \(files.count) files",
        configuration: .init(
            metrics: counted,
            maxDuration: .seconds(30),
            maxIterations: 30,
            thresholds: tolerances,
            setup: {
                // A primed cache: every file a hit, or the benchmark measures the wrong path.
                let primed = await Analyzer().analyze(files: files, cache: cache)
                _ = primed
                let check = await Analyzer().analyze(files: files, cache: cache)
                precondition(
                    check.cacheHits == files.count,
                    "the cache is not warm: \(check.cacheHits) of \(files.count) hits"
                )
            }
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            await blackHole(Analyzer().analyze(files: files, cache: cache))
        }
    }
}

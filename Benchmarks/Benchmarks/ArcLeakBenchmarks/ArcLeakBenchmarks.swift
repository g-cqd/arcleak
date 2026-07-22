import ArcLeakCore
import Benchmark

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

let benchmarks: @Sendable () -> Void = {
    let small = generatedSource(types: 1_000)
    let ring = generatedSource(types: 20_000)

    Benchmark(
        "extract+rules 1k types",
        configuration: .init(metrics: [.cpuTotal, .mallocCountTotal, .peakMemoryResident], maxDuration: .seconds(5))
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
}

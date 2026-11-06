// swift-tools-version: 6.1
import PackageDescription

// Isolated benchmark package: a beta-toolchain incompatibility here can never block the main build. It measures the tree it
// sits in (`path: ".."`), not a published revision, so a change is benchmarked before it is pushed.
let package = Package(
    name: "benchmarks",
    // Tracks the main package's macOS 15 floor (IndexStoreDB in ArcLeakCore).
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        // The facts cache's location type (CorpusScan); the revision arcleak pins.
        .package(url: "https://github.com/g-cqd/analyzerkit.git", revision: "7f612434859324f325977f53f8a4edace7a3dbf7"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.0"),
    ],
    targets: [
        .executableTarget(
            name: "ArcLeakBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "ArcLeakCore", package: "arcleak"),
                .product(name: "CorpusScan", package: "analyzerkit"),
            ],
            path: "Benchmarks/ArcLeakBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark")
            ]
        ),
        .testTarget(
            name: "BenchmarksSmokeTests",
            dependencies: [.product(name: "ArcLeakCore", package: "arcleak")]
        ),
    ]
)

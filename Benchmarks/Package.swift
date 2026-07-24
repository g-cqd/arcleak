// swift-tools-version: 6.1
import PackageDescription

// Isolated benchmark package: a beta-toolchain incompatibility here can never
// block the main build. Baselines are committed; CI checks against them.
let package = Package(
    name: "benchmarks",
    // Tracks the main package's macOS 15 floor (IndexStoreDB in ArcLeakCore).
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.27.0"),
    ],
    targets: [
        .executableTarget(
            name: "ArcLeakBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "ArcLeakCore", package: "arcleak"),
            ],
            path: "Benchmarks/ArcLeakBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .testTarget(
            name: "BenchmarksSmokeTests",
            dependencies: [.product(name: "ArcLeakCore", package: "arcleak")]
        ),
    ]
)

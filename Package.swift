// swift-tools-version: 6.4
import PackageDescription

// Strict-by-default: warnings are errors; upcoming features are on so the code
// is already valid under the next language mode's semantics — including the
// future concurrency defaults (caller-isolated async, inferred isolated
// conformances) — and strict memory safety keeps the unsafe surface at zero.
// Swift 6 language mode (below) already includes complete strict concurrency.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "arcleak",
    // Floor bump 14 → 15: IndexStoreDB (the opt-in `--index-store` backend)
    // targets macOS 15. arcleak is a developer tool, so the bump is acceptable;
    // the syntax-only analysis path is unaffected and Linux builds gate the
    // index out entirely (`#if canImport(IndexStoreDB)`).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ArcLeakCore", targets: ["ArcLeakCore"]),
        .executable(name: "arcleak", targets: ["arcleak"]),
        .plugin(name: "ArcLeakBuildToolPlugin", targets: ["ArcLeakBuildToolPlugin"]),
        .plugin(name: "ArcLeakCommandPlugin", targets: ["ArcLeakCommandPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // indexstore-db has no semver tags — revision-pinned per DESIGN.md.
        // Linked into ArcLeakCore on macOS only (see the target dependency).
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "cb3b960568f18a3cc018923f5824323b5c4edd0b"
        ),
        // ADJSON (g-cqd) backs ONLY the internal, version-gated FactsCache coder
        // — its reflection-free `@JSONCodable` fast path. No tag exists yet, so
        // it is revision-pinned (this commit carries the `JSONWriter(adopting:)`
        // CoW fix the fast encode path needs). Report/SARIF/baseline stay on
        // Foundation: they hash encoded bytes across runs and ADJSON differs on
        // number/slash formatting, which is harmless only inside the cache.
        .package(
            url: "https://github.com/g-cqd/ADJSON.git",
            revision: "1d7fb25c0175f6ff42676dbdd1f104ad29ed8348"
        ),
    ],
    targets: [
        .target(
            name: "ArcLeakCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftIfConfig", package: "swift-syntax"),
                .product(name: "ADJSON", package: "ADJSON"),
                .product(
                    name: "IndexStoreDB",
                    package: "indexstore-db",
                    condition: .when(platforms: [.macOS])
                ),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "arcleak",
            dependencies: [
                "ArcLeakCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        // Runtime ground-truth oracle: proves every KB retention contract by
        // running it. Cycle scenarios are judged externally by `leaks -atExit`;
        // anchor scenarios self-verify with run-loop control. See
        // Scripts/run-leak-oracle.sh. Compiled in language mode 5 on purpose:
        // the scenarios reproduce real-world capture patterns verbatim, and
        // Swift 6 strict concurrency would reject the very shapes under test.
        .executableTarget(
            name: "leak-oracle",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .plugin(
            name: "ArcLeakBuildToolPlugin",
            capability: .buildTool(),
            dependencies: ["arcleak"]
        ),
        .plugin(
            name: "ArcLeakCommandPlugin",
            capability: .command(
                intent: .custom(
                    verb: "arcleak",
                    description: "Analyze Swift sources for retain cycles, leaks, and premature releases"
                )
            ),
            dependencies: ["arcleak"]
        ),
        .testTarget(
            name: "ArcLeakCoreTests",
            dependencies: ["ArcLeakCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

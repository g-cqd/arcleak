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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // swift-system: a safe, Sendable stdio surface (stderr writes; the LSP
        // server's stdin/stdout framing). Foundation's FileHandle is
        // corelibs-only and would re-link ~47 MiB of ICU on Linux.
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        // indexstore-db has no semver tags — revision-pinned per DESIGN.md.
        // Linked into ArcLeakCore on macOS only (see the target dependency).
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "64aa0b26913249c4e7c21d351a215fba02702003"
        ),
        // The pinned JSON package uses Aemi's kernel and runtime products.
        // Only the internal facts cache uses this codec; report byte formats stay stable.
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "5542d37ff0edb17c822b48fe69bff6e792354c57"
        ),
        // The project model the analyzers share: code regions, test code,
        // generated files, platforms and system entry points.
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "191f42626514259ff9cbdaa097adea9d584da672"
        ),
    ],
    targets: [
        .target(
            name: "ArcLeakCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftIfConfig", package: "swift-syntax"),
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit", condition: .when(platforms: [.macOS])),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "WordPiece", package: "analyzerkit"),
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
                .product(name: "AnalyzerCLI", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
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
            dependencies: [
                "ArcLeakCore", .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "WordPiece", package: "analyzerkit"),
            ],
            exclude: ["Goldens"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

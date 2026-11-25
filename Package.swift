// swift-tools-version: 6.4
import PackageDescription

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
        .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "0390867818c28241af4650eb4ef29af5669335a3"
        ),
        .package(
            url: "https://github.com/g-cqd/AemiJSON.git",
            revision: "9144b71be7714e15db293197b47edcc55ffde71b"
        ),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "a472d8c967c0fb6b5cab2e12b011c7a0ca3d9248"
        ),
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "9e38d1bee60d5d65acffef4538c671b49860c6af"),
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "2e54cc659fab831ff3294c00b6e013fca15d45d8"
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
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
                .product(name: "AemiProtobufCore", package: "AemiProtobuf"),
                .product(name: "AemiKernel", package: "aemi"),
                .product(name: "ProjectModel", package: "analyzerkit"),
                .product(name: "CorpusScan", package: "analyzerkit"),
                .product(name: "IndexStoreSupport", package: "analyzerkit", condition: .when(platforms: [.macOS])),
                .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "SemanticEmbedding", package: "analyzerkit"),
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
                .product(name: "SemanticEmbedding", package: "analyzerkit"),
                .product(name: "SourceCorpus", package: "analyzerkit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: strictSwiftSettings
        ),
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
                .product(name: "Suppression", package: "analyzerkit"),
                .product(name: "ReportSupport", package: "analyzerkit"),
                .product(name: "WordPiece", package: "analyzerkit"),
                .product(name: "SemanticEmbedding", package: "analyzerkit"),
                .product(name: "AemiJSON", package: "AemiJSON"),
                .product(name: "AemiProtobuf", package: "AemiProtobuf"),
            ],
            exclude: ["Goldens"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

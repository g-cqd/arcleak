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
            revision: "1c098f0456a2f86dee32dfd9b85455980216589f"
        ),
        .package(
            url: "https://github.com/g-cqd/AemiProtobuf.git",
            revision: "b31d62bbf28286aed1b394c0762257d745bbb530"
        ),
        .package(url: "https://github.com/Aemi-Studio/aemi.git", revision: "bd5e4cf4441ca3ed1b424935142586ccaac0f835"),
        .package(
            url: "https://github.com/g-cqd/analyzerkit.git",
            revision: "3b5d779d61e51a346fcb86c69ac3ab8ebcbdd6c0"
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

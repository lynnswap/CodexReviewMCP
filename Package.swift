// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewMCP",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "ReviewApplication",
            targets: ["ReviewApplication"]
        ),
        .library(
            name: "ReviewTestSupport",
            targets: ["ReviewTestSupport"]
        ),
        .library(
            name: "CodexReviewUI",
            targets: ["CodexReviewUI"]
        ),
        .library(
            name: "ReviewInfrastructure",
            targets: ["ReviewInfrastructure"]
        ),
        .library(
            name: "ReviewAppServerIntegration",
            targets: ["ReviewAppServerIntegration"]
        ),
        .library(
            name: "ReviewMCPAdapter",
            targets: ["ReviewMCPAdapter"]
        ),
        .executable(
            name: "codex-review-mcp",
            targets: ["CodexReviewMCPExecutable"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", .upToNextMinor(from: "0.8.0")),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.4"),
    ],
    targets: [
        .target(
            name: "ReviewDomain",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewApplicationDependencies",
            dependencies: [
                "ReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewInfrastructure",
            dependencies: [
                "ReviewDomain",
            ],
            path: "Sources/ReviewInfrastructure",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewAppServerIntegration",
            dependencies: [
                "ReviewApplicationDependencies",
                "ReviewDomain",
                "ReviewInfrastructure",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/ReviewAppServerIntegration",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewMCPAdapter",
            dependencies: [
                "ReviewDomain",
                "ReviewInfrastructure",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/ReviewMCPAdapter",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewApplication",
            dependencies: [
                "ReviewApplicationDependencies",
                "ReviewAppServerIntegration",
                "ReviewDomain",
                "ReviewInfrastructure",
                "ReviewMCPAdapter",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            path: "Sources/ReviewApplication",
            sources: [
                "CodexReviewModel",
                "CodexReviewMCP",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewUI",
            dependencies: [
                "ReviewApplication",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                "ReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewCLI",
            dependencies: [
                "ReviewApplication",
                "ReviewAppServerIntegration",
                "ReviewInfrastructure",
                "ReviewMCPAdapter",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewTestSupport",
            dependencies: [
                "ReviewApplication",
                "ReviewAppServerIntegration",
                "ReviewDomain",
                "ReviewInfrastructure",
                "ReviewMCPAdapter",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CodexReviewMCPExecutable",
            dependencies: ["ReviewCLI"],
            path: "Sources/CodexReviewMCPExecutable",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CodexReviewMCPServerExecutable",
            dependencies: ["ReviewCLI"],
            path: "Sources/CodexReviewMCPServerExecutable",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewJobsTests",
            dependencies: ["ReviewApplication", "ReviewDomain", "ReviewTestSupport", "ReviewAppServerIntegration", "ReviewInfrastructure", "ReviewMCPAdapter"],
            path: "Tests/ReviewJobsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCoreTests",
            dependencies: ["ReviewApplication", "ReviewApplicationDependencies", "ReviewDomain", "ReviewTestSupport", "ReviewAppServerIntegration", "ReviewInfrastructure", "ReviewMCPAdapter"],
            path: "Tests/ReviewCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewHTTPServerTests",
            dependencies: ["ReviewApplication", "ReviewDomain", "ReviewMCPAdapter"],
            path: "Tests/ReviewHTTPServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCLITests",
            dependencies: ["ReviewApplication", "ReviewCLI", "ReviewDomain", "ReviewAppServerIntegration", "ReviewInfrastructure", "ReviewMCPAdapter"],
            path: "Tests/ReviewCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewStdioAdapterTests",
            dependencies: ["ReviewDomain", "ReviewMCPAdapter", "ReviewTestSupport"],
            path: "Tests/ReviewStdioAdapterTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPTests",
            dependencies: ["ReviewApplication", "ReviewDomain", "ReviewTestSupport", "ReviewAppServerIntegration", "ReviewInfrastructure", "ReviewMCPAdapter"],
            path: "Tests/CodexReviewMCPTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewUITests",
            dependencies: ["CodexReviewUI", "ReviewApplication", "ReviewDomain", "ReviewTestSupport"],
            path: "Tests/CodexReviewUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

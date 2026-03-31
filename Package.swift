// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "CodexReviewModel",
            targets: ["CodexReviewModel"]
        ),
        .library(
            name: "CodexReviewUI",
            targets: ["CodexReviewUI"]
        ),
        .library(
            name: "CodexReviewMCP",
            targets: ["CodexReviewMCP"]
        ),
        .executable(
            name: "codex-review-mcp",
            targets: ["CodexReviewMCPExecutable"]
        ),
        .executable(
            name: "codex-review-mcp-server",
            targets: ["CodexReviewMCPServerExecutable"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", from: "0.6.1"),
    ],
    targets: [
        .target(
            name: "ReviewJobs",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewCore",
            dependencies: [
                "ReviewJobs",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewHTTPServer",
            dependencies: [
                "ReviewCore",
                "ReviewJobs",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewStdioAdapter",
            dependencies: [
                "ReviewCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewRuntime",
            dependencies: [
                "ReviewJobs",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewModel",
            dependencies: [
                "ReviewJobs",
                "ReviewRuntime",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewUI",
            dependencies: [
                "CodexReviewModel",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
                "ReviewJobs",
                "ReviewRuntime",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewCLI",
            dependencies: [
                "CodexReviewMCP",
                "ReviewHTTPServer",
                "ReviewStdioAdapter",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCP",
            dependencies: [
                "CodexReviewModel",
                "ReviewCore",
                "ReviewJobs",
                "ReviewRuntime",
                "ReviewHTTPServer",
                "ReviewStdioAdapter",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
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
            dependencies: ["ReviewJobs", "ReviewCore", "ReviewRuntime", "CodexReviewMCP"],
            path: "Tests/ReviewJobsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCoreTests",
            dependencies: ["ReviewCore", "ReviewJobs"],
            path: "Tests/ReviewCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewHTTPServerTests",
            dependencies: ["ReviewHTTPServer", "ReviewCore", "ReviewJobs", "ReviewRuntime", "CodexReviewMCP"],
            path: "Tests/ReviewHTTPServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCLITests",
            dependencies: ["ReviewCLI", "ReviewCore", "ReviewJobs", "ReviewRuntime"],
            path: "Tests/ReviewCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewStdioAdapterTests",
            dependencies: ["ReviewStdioAdapter", "ReviewHTTPServer", "ReviewCore", "ReviewJobs", "ReviewRuntime"],
            path: "Tests/ReviewStdioAdapterTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPTests",
            dependencies: ["CodexReviewMCP", "CodexReviewModel", "ReviewHTTPServer", "ReviewCore", "ReviewJobs", "ReviewRuntime"],
            path: "Tests/CodexReviewMCPTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewUITests",
            dependencies: ["CodexReviewUI", "CodexReviewModel", "ReviewJobs", "ReviewRuntime"],
            path: "Tests/CodexReviewUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

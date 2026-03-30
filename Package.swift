// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", revision: "6132fd4b5b4217ce4717c4775e4607f5c3120129"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "ReviewCore",
            dependencies: [
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
            name: "ReviewCLI",
            dependencies: [
                "ReviewCore",
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
                "ReviewCore",
                "ReviewHTTPServer",
                "ReviewStdioAdapter",
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
            name: "ReviewCoreTests",
            dependencies: ["ReviewCore"],
            path: "Tests/ReviewCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewHTTPServerTests",
            dependencies: ["ReviewHTTPServer", "ReviewCore"],
            path: "Tests/ReviewHTTPServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCLITests",
            dependencies: ["ReviewCLI", "ReviewCore"],
            path: "Tests/ReviewCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewStdioAdapterTests",
            dependencies: ["ReviewStdioAdapter", "ReviewHTTPServer", "ReviewCore"],
            path: "Tests/ReviewStdioAdapterTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPTests",
            dependencies: ["CodexReviewMCP", "ReviewHTTPServer", "ReviewCore"],
            path: "Tests/CodexReviewMCPTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

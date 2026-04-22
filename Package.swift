// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexReviewMCP",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "CodexReviewModel",
            targets: ["CodexReviewModel"]
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
            name: "CodexReviewMCP",
            targets: ["CodexReviewMCP"]
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
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
        .package(url: "https://github.com/lynnswap/ObservationBridge.git", from: "0.6.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.4"),
    ],
    targets: [
        .target(
            name: "ReviewDomain",
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
                "ReviewDomain",
                "ReviewRuntime",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
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
                "ReviewDomain",
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
                "ReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewModel",
            dependencies: [
                "ReviewDomain",
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
                "ReviewDomain",
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
                "CodexReviewModel",
                "ReviewCore",
                "ReviewDomain",
                "ReviewRuntime",
                "ReviewHTTPServer",
                "ReviewStdioAdapter",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewTestSupport",
            dependencies: [
                "ReviewCore",
                "ReviewDomain",
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
            dependencies: ["ReviewDomain", "ReviewCore", "ReviewRuntime", "CodexReviewMCP", "ReviewTestSupport"],
            path: "Tests/ReviewJobsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCoreTests",
            dependencies: ["ReviewDomain", "ReviewCore", "ReviewRuntime", "ReviewTestSupport"],
            path: "Tests/ReviewCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewHTTPServerTests",
            dependencies: ["ReviewHTTPServer", "ReviewCore", "ReviewDomain", "ReviewRuntime", "CodexReviewMCP"],
            path: "Tests/ReviewHTTPServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCLITests",
            dependencies: ["ReviewCLI", "ReviewCore", "ReviewDomain", "ReviewRuntime"],
            path: "Tests/ReviewCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewStdioAdapterTests",
            dependencies: ["ReviewStdioAdapter", "ReviewHTTPServer", "ReviewCore", "ReviewDomain", "ReviewRuntime", "ReviewTestSupport"],
            path: "Tests/ReviewStdioAdapterTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPTests",
            dependencies: ["CodexReviewMCP", "CodexReviewModel", "ReviewHTTPServer", "ReviewCore", "ReviewDomain", "ReviewRuntime", "ReviewTestSupport"],
            path: "Tests/CodexReviewMCPTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewUITests",
            dependencies: ["CodexReviewUI", "CodexReviewModel", "ReviewDomain", "ReviewRuntime", "ReviewTestSupport"],
            path: "Tests/CodexReviewUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

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
            name: "ReviewUI",
            targets: ["ReviewUI"]
        ),
        .library(
            name: "ReviewPlatform",
            targets: ["ReviewPlatform"]
        ),
        .library(
            name: "ReviewAppServerAdapter",
            targets: ["ReviewAppServerAdapter"]
        ),
        .library(
            name: "ReviewMCPAdapter",
            targets: ["ReviewMCPAdapter"]
        ),
        .library(
            name: "ReviewServiceRuntime",
            targets: ["ReviewServiceRuntime"]
        ),
        .executable(
            name: "codex-review-mcp",
            targets: ["CodexReviewMCPCommand"]
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
            name: "ReviewPorts",
            dependencies: [
                "ReviewDomain",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewPlatform",
            dependencies: [
                "ReviewDomain",
            ],
            path: "Sources/ReviewPlatform",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewAppServerAdapter",
            dependencies: [
                "ReviewPorts",
                "ReviewDomain",
                "ReviewPlatform",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/ReviewAppServerAdapter",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewMCPAdapter",
            dependencies: [
                "ReviewDomain",
                "ReviewPorts",
                "ReviewPlatform",
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
                "ReviewPorts",
                "ReviewDomain",
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
            name: "ReviewServiceRuntime",
            dependencies: [
                "ReviewApplication",
                "ReviewPorts",
                "ReviewAppServerAdapter",
                "ReviewDomain",
                "ReviewPlatform",
                "ReviewMCPAdapter",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            path: "Sources/ReviewServiceRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewUI",
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
                "ReviewAppServerAdapter",
                "ReviewPlatform",
                "ReviewMCPAdapter",
                "ReviewServiceRuntime",
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
                "ReviewAppServerAdapter",
                "ReviewDomain",
                "ReviewPlatform",
                "ReviewMCPAdapter",
                "ReviewServiceRuntime",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CodexReviewMCPCommand",
            dependencies: ["ReviewCLI"],
            path: "Sources/CodexReviewMCPCommand",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CodexReviewMCPServerCommand",
            dependencies: ["ReviewCLI"],
            path: "Sources/CodexReviewMCPServerCommand",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewJobsTests",
            dependencies: ["ReviewApplication", "ReviewDomain", "ReviewTestSupport", "ReviewAppServerAdapter", "ReviewPlatform", "ReviewMCPAdapter", "ReviewServiceRuntime"],
            path: "Tests/ReviewJobsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCoreTests",
            dependencies: ["ReviewApplication", "ReviewPorts", "ReviewDomain", "ReviewTestSupport", "ReviewAppServerAdapter", "ReviewPlatform", "ReviewMCPAdapter", "ReviewServiceRuntime"],
            path: "Tests/ReviewCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewHTTPServerTests",
            dependencies: ["ReviewApplication", "ReviewDomain", "ReviewPorts", "ReviewMCPAdapter"],
            path: "Tests/ReviewHTTPServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCLITests",
            dependencies: ["ReviewApplication", "ReviewCLI", "ReviewDomain", "ReviewAppServerAdapter", "ReviewPlatform", "ReviewMCPAdapter", "ReviewServiceRuntime"],
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
            dependencies: ["ReviewApplication", "ReviewDomain", "ReviewTestSupport", "ReviewAppServerAdapter", "ReviewPlatform", "ReviewMCPAdapter", "ReviewServiceRuntime"],
            path: "Tests/CodexReviewMCPTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewUITests",
            dependencies: ["ReviewUI", "ReviewApplication", "ReviewDomain", "ReviewTestSupport"],
            path: "Tests/ReviewUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

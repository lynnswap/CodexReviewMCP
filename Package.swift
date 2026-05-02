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
        .library(
            name: "ReviewInfra",
            targets: ["ReviewInfra"]
        ),
        .library(
            name: "ReviewApp",
            targets: ["ReviewApp"]
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
            name: "ReviewInfra",
            dependencies: [
                "ReviewApplicationDependencies",
                "ReviewDomain",
                "ReviewRuntime",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "Sources/ReviewInfra",
            sources: [
                "ReviewCore",
                "ReviewHTTPServer",
                "ReviewStdioAdapter",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewCore",
            dependencies: [
                "ReviewInfra",
            ],
            path: "Sources/ReviewCoreFacade",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewHTTPServer",
            dependencies: [
                "ReviewInfra",
            ],
            path: "Sources/ReviewHTTPServerFacade",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewStdioAdapter",
            dependencies: [
                "ReviewInfra",
            ],
            path: "Sources/ReviewStdioAdapterFacade",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewApp",
            dependencies: [
                "ReviewApplicationDependencies",
                "ReviewDomain",
                "ReviewInfra",
                "ReviewRuntime",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            path: "Sources/ReviewApp",
            sources: [
                "CodexReviewModel",
                "CodexReviewMCP",
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
                "ReviewApp",
            ],
            path: "Sources/CodexReviewModelFacade",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewUI",
            dependencies: [
                "ReviewApp",
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
                "ReviewApp",
                "ReviewInfra",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CodexReviewMCP",
            dependencies: [
                "ReviewApp",
                .product(name: "ObservationBridge", package: "ObservationBridge"),
            ],
            path: "Sources/CodexReviewMCPFacade",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ReviewTestSupport",
            dependencies: [
                "ReviewApp",
                "ReviewInfra",
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
            dependencies: ["ReviewDomain", "ReviewCore", "ReviewRuntime", "CodexReviewMCP", "ReviewTestSupport", "ReviewApp", "ReviewInfra"],
            path: "Tests/ReviewJobsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCoreTests",
            dependencies: ["ReviewApplicationDependencies", "ReviewDomain", "ReviewCore", "ReviewRuntime", "ReviewTestSupport", "ReviewInfra"],
            path: "Tests/ReviewCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewHTTPServerTests",
            dependencies: ["ReviewHTTPServer", "ReviewCore", "ReviewDomain", "ReviewRuntime", "CodexReviewMCP", "ReviewInfra"],
            path: "Tests/ReviewHTTPServerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewCLITests",
            dependencies: ["ReviewCLI", "ReviewCore", "ReviewDomain", "ReviewRuntime", "ReviewApp", "ReviewInfra"],
            path: "Tests/ReviewCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ReviewStdioAdapterTests",
            dependencies: ["ReviewStdioAdapter", "ReviewHTTPServer", "ReviewCore", "ReviewDomain", "ReviewRuntime", "ReviewTestSupport", "ReviewInfra"],
            path: "Tests/ReviewStdioAdapterTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewMCPTests",
            dependencies: ["CodexReviewMCP", "CodexReviewModel", "ReviewHTTPServer", "ReviewCore", "ReviewDomain", "ReviewRuntime", "ReviewTestSupport", "ReviewApp", "ReviewInfra"],
            path: "Tests/CodexReviewMCPTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CodexReviewUITests",
            dependencies: ["CodexReviewUI", "CodexReviewModel", "ReviewDomain", "ReviewRuntime", "ReviewTestSupport", "ReviewApp"],
            path: "Tests/CodexReviewUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

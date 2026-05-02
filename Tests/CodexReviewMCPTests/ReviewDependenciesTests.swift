import Foundation
import Testing
import ReviewTestSupport
@testable import ReviewAppServerIntegration
@testable import ReviewInfrastructure
@testable import ReviewMCPAdapter
@_spi(Testing) @testable import ReviewApp

@Suite(.serialized)
@MainActor
struct ReviewDependenciesTests {
    @Test func testHomeStartsStoreInsideInjectedReviewHome() async throws {
        let testHome = try ReviewDependencies.testHome()
        defer {
            try? FileManager.default.removeItem(at: testHome.homeURL)
        }
        let store = CodexReviewStore(dependencies: testHome.dependencies)
        let reviewHomeURL = testHome.homeURL.appendingPathComponent(".codex_review", isDirectory: true)
        let discoveryURL = reviewHomeURL.appendingPathComponent("review_mcp_endpoint.json")
        let runtimeStateURL = reviewHomeURL.appendingPathComponent("review_mcp_runtime_state.json")

        await store.start()
        #expect(store.serverState == .running)
        #expect(FileManager.default.fileExists(atPath: discoveryURL.path))
        #expect(FileManager.default.fileExists(atPath: runtimeStateURL.path))

        await store.stop()
        #expect(FileManager.default.fileExists(atPath: discoveryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: runtimeStateURL.path) == false)
    }

    @Test func localConfigClientReadsFromInjectedHome() throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let core = ReviewCoreDependencies(environment: ["HOME": rootURL.path])
        let configURL = core.paths.reviewConfigURL()
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"review_model = "gpt-test""#.write(to: configURL, atomically: true, encoding: .utf8)

        let config = try ReviewLocalConfigClient(dependencies: core).load()

        #expect(config.reviewModel == "gpt-test")
    }

    @Test func previewDependenciesDoNotPointAtRealReviewHome() {
        let dependencies = ReviewDependencies.preview()
        let realReviewHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex_review", isDirectory: true)

        #expect(dependencies.core.paths.reviewHomeURL().path != realReviewHome.path)
    }

    @Test func previewDependenciesUseUniqueReviewHomes() {
        let first = ReviewDependencies.preview()
        let second = ReviewDependencies.preview()

        #expect(first.core.paths.reviewHomeURL().path != second.core.paths.reviewHomeURL().path)
    }

    @Test func coreDependenciesReplacingEnvironmentPreservesExplicitPathsForSameEnvironment() throws {
        let environmentRootURL = try makeTemporaryDirectory()
        let injectedRootURL = try makeTemporaryDirectory()
        let probeRootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: environmentRootURL)
            try? FileManager.default.removeItem(at: injectedRootURL)
            try? FileManager.default.removeItem(at: probeRootURL)
        }
        let environment = ["HOME": environmentRootURL.path]
        let core = ReviewCoreDependencies(
            environment: environment,
            paths: .init(
                environment: ["HOME": injectedRootURL.path],
                homeDirectoryForCurrentUser: environmentRootURL
            )
        )

        let sameEnvironment = core.replacingEnvironment(environment)
        let probeEnvironment = core.replacingEnvironment(["HOME": probeRootURL.path])

        #expect(sameEnvironment.paths.reviewHomeURL().path == core.paths.reviewHomeURL().path)
        #expect(probeEnvironment.paths.reviewHomeURL().path == probeRootURL
            .appendingPathComponent(".codex_review", isDirectory: true)
            .path)
    }

    @Test func accountRegistryUsesInjectedPaths() throws {
        let environmentRootURL = try makeTemporaryDirectory()
        let injectedRootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: environmentRootURL)
            try? FileManager.default.removeItem(at: injectedRootURL)
        }
        let core = ReviewCoreDependencies(
            environment: ["HOME": environmentRootURL.path],
            paths: .init(
                environment: ["HOME": injectedRootURL.path],
                homeDirectoryForCurrentUser: injectedRootURL
            )
        )
        let authURL = core.paths.reviewAuthURL()
        try writeReviewAuthSnapshot(
            email: "injected@example.com",
            planType: "pro",
            environment: ["HOME": injectedRootURL.path]
        )

        let registryStore = ReviewAccountRegistryStore(coreDependencies: core)
        let savedAccount = try #require(
            try registryStore.saveSharedAuthAsSavedAccount(makeActive: true)
        )

        #expect(savedAccount.email == "injected@example.com")
        #expect(FileManager.default.fileExists(atPath: authURL.path))
        #expect(FileManager.default.fileExists(atPath: core.paths.accountsRegistryURL().path))
        #expect(
            FileManager.default.fileExists(
                atPath: ReviewHomePaths.accountsRegistryURL(environment: core.environment).path
            ) == false
        )
        #expect(loadRegisteredReviewAccounts(dependencies: core).activeAccountKey == savedAccount.accountKey)
    }
}

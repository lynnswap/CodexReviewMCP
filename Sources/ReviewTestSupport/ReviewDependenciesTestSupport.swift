import Foundation
import ReviewApplication
package import ReviewAppServerIntegration
package import ReviewInfrastructure
package import ReviewMCPAdapter

package struct ReviewDependencyTestHome {
    package var homeURL: URL
    package var clock: ManualTestClock
    package var appServerManager: MockAppServerManager
    package var dependencies: ReviewDependencies
}

package actor SignedOutTestReviewAuthSession: ReviewAuthSession {
    package init() {}

    package func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        .init(account: nil, requiresOpenAIAuth: true)
    }

    package func startLogin(_: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        .chatGPT(loginID: "test-login", authURL: "https://example.test/login")
    }

    package func cancelLogin(loginID _: String) async throws {}

    package func logout() async throws {}

    package func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    package func close() async {}
}

@MainActor
package extension ReviewDependencies {
    static func testHome(
        modeProvider: @escaping @Sendable (String) -> MockAppServerMode = { _ in .success() },
        authSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession = { _ in
            SignedOutTestReviewAuthSession()
        }
    ) throws -> ReviewDependencyTestHome {
        let homeURL = try makeReviewDependencyTestHomeURL()
        let environment = ["HOME": homeURL.path]
        let clock = ManualTestClock()
        let core = ReviewCoreDependencies(
            environment: environment,
            fileSystem: .live,
            process: .live,
            clock: clock
        )
        let configuration = ReviewServerConfiguration(
            port: 0,
            shouldAutoStartEmbeddedServer: false,
            environment: environment,
            coreDependencies: core
        )
        let appServerManager = MockAppServerManager(modeProvider: modeProvider)
        let dependencies = ReviewDependencies.testing(
            configuration: configuration,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: authSessionFactory,
            loginAuthSessionFactory: authSessionFactory,
            rateLimitObservationClock: clock
        )
        return .init(
            homeURL: homeURL,
            clock: clock,
            appServerManager: appServerManager,
            dependencies: dependencies
        )
    }
}

private func makeReviewDependencyTestHomeURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

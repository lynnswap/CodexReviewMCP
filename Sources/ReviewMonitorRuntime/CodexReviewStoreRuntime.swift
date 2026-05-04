import Foundation
import ReviewApplication
import ReviewAppServerIntegration
import ReviewInfrastructure
import ReviewMCPAdapter

extension CodexReviewStore {
    public convenience init() {
        self.init(dependencies: .live(
            runtimeDependencies: .live()
        ))
    }

    package convenience init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        authSessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        let sharedFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
        let loginFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
        if let authSessionFactory {
            sharedFactory = { (_: [String: String]) async throws -> any ReviewAuthSession in
                try await authSessionFactory()
            }
            loginFactory = { environment in
                let baseSession = try await authSessionFactory()
                return try await LegacyProbeScopedReviewAuthSession(
                    base: baseSession,
                    sharedDependencies: configuration.coreDependencies,
                    probeDependencies: configuration.coreDependencies.replacingEnvironment(environment)
                )
            }
        } else {
            sharedFactory = nil
            loginFactory = nil
        }
        self.init(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedFactory,
            loginAuthSessionFactory: loginFactory,
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
    }

    package convenience init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        probeAppServerManagerFactory: ReviewMonitorRuntimeDependencies.ProbeAppServerManagerFactory? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        self.init(dependencies: .live(
            runtimeDependencies: .live(
                configuration: configuration,
                diagnosticsURL: diagnosticsURL,
                appServerManager: appServerManager,
                sharedAuthSessionFactory: sharedAuthSessionFactory,
                loginAuthSessionFactory: loginAuthSessionFactory,
                probeAppServerManagerFactory: probeAppServerManagerFactory,
                rateLimitObservationClock: rateLimitObservationClock,
                rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
                inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
                deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
            )
        ))
    }

    package static func makeConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> ReviewServerConfiguration {
        let coreDependencies = ReviewCoreDependencies.live(
            environment: environment,
            arguments: arguments
        )
        let port = environment[CodexReviewStoreTestEnvironment.portKey]
            .flatMap(Int.init)
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.portArgument,
                arguments: arguments
            ).flatMap(Int.init)
            ?? ReviewServerConfiguration().port
        let codexCommand = environment[CodexReviewStoreTestEnvironment.codexCommandKey]
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.codexCommandArgument,
                arguments: arguments
            )
            ?? "codex"
        return .init(
            port: port,
            codexCommand: codexCommand,
            shouldAutoStartEmbeddedServer: CodexReviewStoreLaunchPolicy.shouldAutoStartEmbeddedServer(
                environment: environment,
                arguments: arguments
            ),
            environment: environment,
            coreDependencies: coreDependencies
        )
    }

    package static func makeDiagnosticsURL(
        environment: [String: String],
        arguments: [String]
    ) -> URL? {
        guard let path = environment[CodexReviewStoreTestEnvironment.diagnosticsPathKey]
            ?? argumentValue(
                flag: CodexReviewStoreTestEnvironment.diagnosticsPathArgument,
                arguments: arguments
            ),
            path.isEmpty == false
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    package static func argumentValue(
        flag: String,
        arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index))
        else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}

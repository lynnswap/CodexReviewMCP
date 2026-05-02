import Foundation
import ReviewApplication
import ReviewAppServerIntegration
import ReviewDomain
import ReviewInfrastructure
import ReviewMCPAdapter

@MainActor
package extension ReviewDependencies {
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration? = nil
    ) -> Self {
        let configuration = CodexReviewStore.makeConfiguration(
            environment: environment,
            arguments: arguments
        )
        let diagnosticsURL = CodexReviewStore.makeDiagnosticsURL(
            environment: environment,
            arguments: arguments
        )
        let appServerManager = AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment,
                clock: configuration.coreDependencies.clock,
                coreDependencies: configuration.coreDependencies
            )
        )
        if let nativeAuthenticationConfiguration {
            let loginAuthSessionFactory = CodexReviewStore.makeReviewMonitorLoginAuthSessionFactory(
                configuration: configuration,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: ReviewMonitorWebAuthenticationSession.startSystem
            )
            return live(
                configuration: configuration,
                diagnosticsURL: diagnosticsURL,
                appServerManager: appServerManager,
                loginAuthSessionFactory: loginAuthSessionFactory,
                deferStartupAuthRefreshUntilPrepared: true
            )
        }
        return live(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager
        )
    }

    static func live(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> Self {
        let components = ReviewMonitorCoordinator.live(
            configuration: configuration,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory,
            rateLimitObservationClock: rateLimitObservationClock ?? configuration.coreDependencies.clock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
        return .init(
            core: .init(
                dateNow: configuration.coreDependencies.dateNow,
                uuid: configuration.coreDependencies.uuid
            ),
            coordinator: components.coordinator,
            settingsService: components.settingsService,
            diagnosticsURL: diagnosticsURL
        )
    }

    static func testing(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: any AppServerManaging,
        sharedAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        loginAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> Self {
        live(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory,
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
    }
}

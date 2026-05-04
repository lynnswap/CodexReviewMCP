import Foundation
import ReviewApplication
import ReviewAppServerIntegration
import ReviewInfrastructure
import ReviewMCPAdapter

@MainActor
package extension ReviewDependencies {
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration? = nil
    ) -> Self {
        live(runtimeDependencies: .live(
            environment: environment,
            arguments: arguments,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration
        ))
    }

    static func live(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        probeAppServerManagerFactory: ReviewMonitorRuntimeDependencies.ProbeAppServerManagerFactory? = nil,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> Self {
        live(runtimeDependencies: .live(
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
        ))
    }

    static func live(
        runtimeDependencies: ReviewMonitorRuntimeDependencies
    ) -> Self {
        let components = ReviewMonitorCoordinator.live(
            runtimeDependencies: runtimeDependencies
        )
        let configuration = runtimeDependencies.configuration
        return .init(
            core: .init(
                dateNow: configuration.coreDependencies.dateNow,
                uuid: configuration.coreDependencies.uuid
            ),
            coordinator: components.coordinator,
            settingsService: components.settingsService,
            diagnosticsURL: runtimeDependencies.diagnosticsURL
        )
    }

    static func testing(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: any AppServerManaging,
        sharedAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        loginAuthSessionFactory: @escaping @Sendable ([String: String]) async throws -> any ReviewAuthSession,
        probeAppServerManagerFactory: ReviewMonitorRuntimeDependencies.ProbeAppServerManagerFactory? = nil,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> Self {
        live(runtimeDependencies: .testing(
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
        ))
    }
}

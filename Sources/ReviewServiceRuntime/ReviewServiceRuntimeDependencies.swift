import Foundation
import ReviewApplication
import ReviewAppServerAdapter
import ReviewPlatform
import ReviewMCPAdapter

@MainActor
package struct ReviewServiceRuntimeDependencies {
    package typealias AuthSessionFactory = @Sendable ([String: String]) async throws -> any ReviewAuthSession
    package typealias ProbeAppServerManagerFactory = @Sendable ([String: String]) -> any AppServerManaging

    package let configuration: ReviewServerConfiguration
    package let diagnosticsURL: URL?
    package let appServerManager: any AppServerManaging
    package let sharedAuthSessionFactory: AuthSessionFactory?
    package let loginAuthSessionFactory: AuthSessionFactory?
    package let probeAppServerManagerFactory: ProbeAppServerManagerFactory
    package let rateLimitObservationClock: any ReviewClock
    package let rateLimitStaleRefreshInterval: Duration
    package let inactiveRateLimitRefreshInterval: Duration
    package let deferStartupAuthRefreshUntilPrepared: Bool

    package init(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: AuthSessionFactory? = nil,
        loginAuthSessionFactory: AuthSessionFactory? = nil,
        probeAppServerManagerFactory: ProbeAppServerManagerFactory? = nil,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        self.configuration = configuration
        self.diagnosticsURL = diagnosticsURL
        self.appServerManager = appServerManager ?? Self.makeAppServerManager(
            configuration: configuration
        )
        self.sharedAuthSessionFactory = sharedAuthSessionFactory
        self.loginAuthSessionFactory = loginAuthSessionFactory
        self.probeAppServerManagerFactory = probeAppServerManagerFactory ?? Self.makeProbeAppServerManagerFactory(
            configuration: configuration
        )
        self.rateLimitObservationClock = rateLimitObservationClock ?? configuration.coreDependencies.clock
        self.rateLimitStaleRefreshInterval = rateLimitStaleRefreshInterval
        self.inactiveRateLimitRefreshInterval = inactiveRateLimitRefreshInterval
        self.deferStartupAuthRefreshUntilPrepared = deferStartupAuthRefreshUntilPrepared
    }

    package static func live(
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
        if let nativeAuthenticationConfiguration {
            let loginAuthSessionFactory = CodexReviewStore.makeReviewMonitorLoginAuthSessionFactory(
                configuration: configuration,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                webAuthenticationSessionFactory: ReviewMonitorWebAuthenticationSession.startSystem
            )
            return .init(
                configuration: configuration,
                diagnosticsURL: diagnosticsURL,
                loginAuthSessionFactory: loginAuthSessionFactory,
                deferStartupAuthRefreshUntilPrepared: true
            )
        }
        return .init(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL
        )
    }

    package static func live(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: AuthSessionFactory? = nil,
        loginAuthSessionFactory: AuthSessionFactory? = nil,
        probeAppServerManagerFactory: ProbeAppServerManagerFactory? = nil,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> Self {
        .init(
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
    }

    package static func testing(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: any AppServerManaging,
        sharedAuthSessionFactory: @escaping AuthSessionFactory,
        loginAuthSessionFactory: @escaping AuthSessionFactory,
        probeAppServerManagerFactory: ProbeAppServerManagerFactory? = nil,
        rateLimitObservationClock: (any ReviewClock)? = nil,
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> Self {
        .init(
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
    }

    package static func makeAppServerManager(
        configuration: ReviewServerConfiguration
    ) -> any AppServerManaging {
        AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment,
                clock: configuration.coreDependencies.clock,
                coreDependencies: configuration.coreDependencies
            )
        )
    }

    private static func makeProbeAppServerManagerFactory(
        configuration: ReviewServerConfiguration
    ) -> ProbeAppServerManagerFactory {
        let codexCommand = configuration.codexCommand
        let coreDependencies = configuration.coreDependencies
        return { environment in
            AppServerSupervisor(
                configuration: .init(
                    codexCommand: codexCommand,
                    environment: environment,
                    coreDependencies: coreDependencies.replacingEnvironment(environment)
                )
            )
        }
    }
}

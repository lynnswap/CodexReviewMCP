import Foundation
import ReviewDomain
import ReviewInfra

@MainActor
package struct ReviewDependencies {
    package let core: ReviewCoreDependencies
    package let coordinator: ReviewMonitorCoordinator
    package let settingsService: ReviewMonitorSettingsService
    package let diagnosticsURL: URL?

    package init(
        core: ReviewCoreDependencies,
        coordinator: ReviewMonitorCoordinator,
        settingsService: ReviewMonitorSettingsService,
        diagnosticsURL: URL? = nil
    ) {
        self.core = core
        self.coordinator = coordinator
        self.settingsService = settingsService
        self.diagnosticsURL = diagnosticsURL
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
        let appServerManager = AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment,
                clock: configuration.coreDependencies.clock
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

    package static func live(
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
        let core = configuration.coreDependencies
        let components = ReviewMonitorCoordinator.live(
            configuration: configuration,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory,
            rateLimitObservationClock: rateLimitObservationClock ?? core.clock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
        return .init(
            core: core,
            coordinator: components.coordinator,
            settingsService: components.settingsService,
            diagnosticsURL: diagnosticsURL
        )
    }

    package static func testing(
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

    package static func preview(
        seed: ReviewMonitorCoordinator.Seed = .init(),
        diagnosticsURL: URL? = nil
    ) -> Self {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-review-preview", isDirectory: true)
            .path
        let core = ReviewCoreDependencies(environment: environment)
        let harness = ReviewMonitorTestingHarness(seed: seed)
        return .init(
            core: core,
            coordinator: .init(harness: harness),
            settingsService: .init(
                initialSnapshot: harness.currentSettingsSnapshot,
                harness: harness
            ),
            diagnosticsURL: diagnosticsURL
        )
    }
}

@MainActor
extension CodexReviewStore {
    package convenience init(dependencies: ReviewDependencies) {
        self.init(
            coreDependencies: dependencies.core,
            coordinator: dependencies.coordinator,
            settingsService: dependencies.settingsService,
            diagnosticsURL: dependencies.diagnosticsURL
        )
    }
}

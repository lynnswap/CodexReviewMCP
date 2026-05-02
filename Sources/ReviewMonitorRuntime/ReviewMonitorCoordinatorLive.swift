import Foundation
import ReviewApplication
import ReviewAppServerIntegration
import ReviewInfrastructure
import ReviewMCPAdapter

@MainActor
package struct ReviewMonitorCoordinatorComponents {
    let coordinator: ReviewMonitorCoordinator
    let settingsService: ReviewMonitorSettingsService
}

@MainActor
extension ReviewMonitorCoordinator {
    static func live(
        configuration: ReviewServerConfiguration,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) -> ReviewMonitorCoordinatorComponents {
        let serverRuntime = ReviewMonitorServerRuntime(
            configuration: configuration,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory,
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
        )
        let settingsService = ReviewMonitorSettingsService(
            initialSnapshot: serverRuntime.initialSettingsSnapshot,
            backend: serverRuntime
        )
        let executionCoordinator = ReviewExecutionCoordinator(
            configuration: .init(
                dateNow: configuration.coreDependencies.dateNow
            ),
            reviewEngine: AppServerReviewEngine(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: configuration.environment,
                    coreDependencies: configuration.coreDependencies
                ),
                appServerManager: serverRuntime.appServerManager,
                runtimeStateDidChange: { [weak serverRuntime] runtimeState in
                    await MainActor.run {
                        guard let serverRuntime, let server = serverRuntime.currentServer else {
                            return
                        }
                        serverRuntime.writeRuntimeState(
                            endpointRecord: server.currentEndpointRecord(),
                            appServerRuntimeState: runtimeState
                        )
                    }
                }
            )
        )
        let authOrchestrator = ReviewMonitorAuthOrchestrator(
            configuration: configuration,
            accountRegistryStore: serverRuntime.accountRegistryStore,
            appServerManager: serverRuntime.appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory ?? serverRuntime.liveSharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory ?? serverRuntime.liveCLIAuthSessionFactory,
            runtimeBridge: .live(serverRuntime),
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval
        )
        serverRuntime.authOrchestrator = authOrchestrator
        serverRuntime.executionCoordinator = executionCoordinator
        serverRuntime.settingsService = settingsService
        let seed = ReviewMonitorCoordinator.Seed(
            shouldAutoStartEmbeddedServer: serverRuntime.shouldAutoStartEmbeddedServer,
            initialAccount: serverRuntime.initialAccount,
            initialAccounts: serverRuntime.initialAccounts,
            initialActiveAccountKey: serverRuntime.initialActiveAccountKey,
            initialSettingsSnapshot: serverRuntime.initialSettingsSnapshot
        )
        return .init(
            coordinator: .init(
                seed: seed,
                serverRuntime: serverRuntime,
                authOrchestrator: authOrchestrator,
                executionCoordinator: executionCoordinator
            ),
            settingsService: settingsService
        )
    }
}

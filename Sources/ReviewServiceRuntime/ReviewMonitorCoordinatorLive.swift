import Foundation
import ReviewApplication
import ReviewAppServerAdapter
import ReviewPlatform
import ReviewMCPAdapter

@MainActor
package struct ReviewMonitorCoordinatorComponents {
    let coordinator: ReviewMonitorCoordinator
    let settingsService: ReviewMonitorSettingsService
}

@MainActor
extension ReviewMonitorCoordinator {
    static func live(
        runtimeDependencies: ReviewServiceRuntimeDependencies
    ) -> ReviewMonitorCoordinatorComponents {
        let configuration = runtimeDependencies.configuration
        let serverRuntime = ReviewMonitorServerRuntime(
            dependencies: runtimeDependencies
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
            sharedAuthSessionFactory: runtimeDependencies.sharedAuthSessionFactory ?? serverRuntime.liveSharedAuthSessionFactory,
            loginAuthSessionFactory: runtimeDependencies.loginAuthSessionFactory ?? serverRuntime.liveCLIAuthSessionFactory,
            probeAppServerManagerFactory: runtimeDependencies.probeAppServerManagerFactory,
            runtimeBridge: .live(serverRuntime),
            rateLimitObservationClock: runtimeDependencies.rateLimitObservationClock,
            rateLimitStaleRefreshInterval: runtimeDependencies.rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: runtimeDependencies.inactiveRateLimitRefreshInterval
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

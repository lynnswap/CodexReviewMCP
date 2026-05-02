import Foundation
import ReviewApplicationDependencies
import ReviewDomain

package actor AppServerReviewEngine: ReviewEngine {
    package struct Configuration: Sendable {
        package var defaultTimeoutSeconds: Int?
        package var codexCommand: String
        package var environment: [String: String]
        package var coreDependencies: ReviewCoreDependencies

        package init(
            defaultTimeoutSeconds: Int? = nil,
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            coreDependencies: ReviewCoreDependencies? = nil
        ) {
            let resolvedCoreDependencies = coreDependencies ?? .live(environment: environment)
            self.defaultTimeoutSeconds = defaultTimeoutSeconds
            self.codexCommand = codexCommand
            self.environment = resolvedCoreDependencies.environment
            self.coreDependencies = resolvedCoreDependencies
        }
    }

    private let configuration: Configuration
    private let appServerManager: any AppServerManaging
    private let runtimeStateDidChange: @Sendable (AppServerRuntimeState) async -> Void
    private var bootstrapTransports: [String: any AppServerSessionTransport] = [:]

    package init(
        configuration: Configuration = .init(),
        appServerManager: any AppServerManaging,
        runtimeStateDidChange: @escaping @Sendable (AppServerRuntimeState) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.appServerManager = appServerManager
        self.runtimeStateDidChange = runtimeStateDidChange
    }

    package func initialReviewModel() async -> String? {
        let localConfig = (try? ReviewLocalConfigClient(dependencies: configuration.coreDependencies).load()) ?? .init()
        let codexHome = configuration.coreDependencies.paths.codexHomeURL()
        let fallbackConfig = loadFallbackAppServerConfig(
            environment: configuration.environment,
            codexHome: codexHome
        )
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment,
            codexHome: codexHome
        )
        return resolveReviewModelSelection(
            localConfig: localConfig,
            resolvedConfig: fallbackConfig,
            profileClearsReviewModel: profileClearsReviewModel
        ).reportedModelBeforeThreadStart
    }

    package func runReview(
        jobID: String,
        sessionID: String,
        request: ReviewRequestOptions,
        resolvedModelHint: String?,
        stateChangeStream: AsyncStream<Void>,
        onStart: @escaping @Sendable (Date) async -> Void,
        onReviewStarted: @escaping @Sendable () async -> Void = {},
        onEvent: @escaping @Sendable (ReviewProcessEvent) async -> Void,
        requestedTerminationReason: @escaping @Sendable () async -> ReviewTerminationReason?
    ) async throws -> ReviewProcessOutcome {
        var runner = AppServerReviewRunner(
            settingsBuilder: ReviewExecutionSettingsBuilder(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment
            ),
            coreDependencies: configuration.coreDependencies
        )
        runner.clock = configuration.coreDependencies.clock

        if case .cancelled(let reason)? = await requestedTerminationReason() {
            throw ReviewBootstrapFailure(message: reason.message, model: resolvedModelHint)
        }

        let transport = try await appServerManager.checkoutTransport(sessionID: sessionID)
        storeBootstrapTransport(transport, jobID: jobID)
        if let runtimeState = await appServerManager.currentRuntimeState() {
            await runtimeStateDidChange(runtimeState)
        }
        if case .cancelled(let reason)? = await requestedTerminationReason() {
            clearBootstrapTransport(jobID: jobID)
            await transport.close()
            throw ReviewBootstrapFailure(message: reason.message, model: resolvedModelHint)
        }

        do {
            let outcome = try await runner.run(
                session: transport,
                request: request,
                defaultTimeoutSeconds: configuration.defaultTimeoutSeconds,
                resolvedModelHint: resolvedModelHint,
                diagnosticLineStream: await appServerManager.diagnosticLineStream(),
                stateChangeStream: stateChangeStream,
                diagnosticsTail: { [appServerManager] in
                    await appServerManager.diagnosticsTail()
                },
                onStart: onStart,
                onReviewStarted: {
                    await onReviewStarted()
                    await self.clearBootstrapTransport(jobID: jobID)
                },
                onEvent: onEvent,
                requestedTerminationReason: {
                    await requestedTerminationReason()
                }
            )
            clearBootstrapTransport(jobID: jobID)
            await transport.close()
            return outcome
        } catch {
            clearBootstrapTransport(jobID: jobID)
            await transport.close()
            throw error
        }
    }

    @discardableResult
    package func interruptReview(jobID: String) async -> Bool {
        guard let transport = bootstrapTransports[jobID] else {
            return false
        }
        await transport.close()
        return true
    }

    private func storeBootstrapTransport(
        _ transport: any AppServerSessionTransport,
        jobID: String
    ) {
        bootstrapTransports[jobID] = transport
    }

    private func clearBootstrapTransport(jobID: String) {
        bootstrapTransports[jobID] = nil
    }
}

import AppKit
import AuthenticationServices
import Foundation
import ReviewApplication
import ReviewAppServerIntegration
import ReviewInfrastructure
import ReviewMCPAdapter

@MainActor
public struct ReviewMonitorNativeAuthenticationConfiguration: Sendable {
    public enum BrowserSessionPolicy: Sendable {
        case ephemeral
    }

    public var callbackScheme: String
    public var browserSessionPolicy: BrowserSessionPolicy
    public var presentationAnchorProvider: @MainActor @Sendable () -> ASPresentationAnchor?

    public init(
        callbackScheme: String,
        browserSessionPolicy: BrowserSessionPolicy,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.callbackScheme = callbackScheme
        self.browserSessionPolicy = browserSessionPolicy
        self.presentationAnchorProvider = presentationAnchorProvider
    }
}

@MainActor
extension CodexReviewStore {
    public static func makeReviewMonitorStore(
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration
    ) -> CodexReviewStore {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        return CodexReviewStore(dependencies: .live(
            runtimeDependencies: .live(
                environment: environment,
                arguments: arguments,
                nativeAuthenticationConfiguration: nativeAuthenticationConfiguration
            )
        ))
    }

    static func makeReviewMonitorStore(
        configuration: ReviewServerConfiguration,
        diagnosticsURL: URL? = nil,
        appServerManager: any AppServerManaging,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
        webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory,
        loginAuthSessionFactoryOverride: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil
    ) -> CodexReviewStore {
        let loginAuthSessionFactory = makeReviewMonitorLoginAuthSessionFactory(
            configuration: configuration,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
            webAuthenticationSessionFactory: webAuthenticationSessionFactory
        )

        return CodexReviewStore(dependencies: .live(
            runtimeDependencies: .live(
                configuration: configuration,
                diagnosticsURL: diagnosticsURL,
                appServerManager: appServerManager,
                loginAuthSessionFactory: loginAuthSessionFactoryOverride ?? loginAuthSessionFactory,
                deferStartupAuthRefreshUntilPrepared: true
            )
        ))
    }

    static func makeReviewMonitorLoginAuthSessionFactory(
        configuration: ReviewServerConfiguration,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
        webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory,
        runtimeManagerFactory: (@Sendable ([String: String]) -> any AppServerManaging)? = nil
    ) -> @Sendable ([String: String]) async throws -> any ReviewAuthSession {
        { environment in
            let runtimeManager = runtimeManagerFactory?(environment) ?? AppServerSupervisor(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: environment,
                    coreDependencies: configuration.coreDependencies.replacingEnvironment(environment)
                )
            )
            do {
                let transport = try await runtimeManager.checkoutAuthTransport()
                return await MainActor.run {
                    NativeWebAuthenticationReviewSession(
                        sharedSession: SharedAppServerReviewAuthSession(transport: transport),
                        nativeAuthenticationConfiguration: nativeAuthenticationConfiguration,
                        webAuthenticationSessionFactory: webAuthenticationSessionFactory,
                        onClose: { [runtimeManager] in
                            await runtimeManager.shutdown()
                        }
                    )
                }
            } catch {
                await runtimeManager.shutdown()
                throw error
            }
        }
    }
}

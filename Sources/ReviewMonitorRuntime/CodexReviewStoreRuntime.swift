import AppKit
import AuthenticationServices
import Darwin
import Foundation
import Observation
import ObservationBridge
import ReviewApplication
import ReviewAppServerIntegration
import ReviewApplicationDependencies
import ReviewDomain
import ReviewInfrastructure
import ReviewMCPAdapter

extension CodexReviewStore {
    public convenience init() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments
        self.init(dependencies: .live(
            configuration: Self.makeConfiguration(
                environment: environment,
                arguments: arguments
            ),
            diagnosticsURL: Self.makeDiagnosticsURL(
                environment: environment,
                arguments: arguments
            )
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
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        self.init(dependencies: .live(
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            sharedAuthSessionFactory: sharedAuthSessionFactory,
            loginAuthSessionFactory: loginAuthSessionFactory,
            rateLimitObservationClock: rateLimitObservationClock,
            rateLimitStaleRefreshInterval: rateLimitStaleRefreshInterval,
            inactiveRateLimitRefreshInterval: inactiveRateLimitRefreshInterval,
            deferStartupAuthRefreshUntilPrepared: deferStartupAuthRefreshUntilPrepared
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
            environment: environment,
            arguments: arguments,
            nativeAuthenticationConfiguration: nativeAuthenticationConfiguration
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
            configuration: configuration,
            diagnosticsURL: diagnosticsURL,
            appServerManager: appServerManager,
            loginAuthSessionFactory: loginAuthSessionFactoryOverride ?? loginAuthSessionFactory,
            deferStartupAuthRefreshUntilPrepared: true
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

private actor LegacyProbeScopedReviewAuthSession: ReviewAuthSession {
    private let base: any ReviewAuthSession
    private let fileSystem: ReviewFileSystemClient
    private let sharedAuthURL: URL
    private let probeAuthURL: URL
    private let originalSharedAuthData: Data?
    private let originalSharedAuthEmail: String?
    private var restoredSharedAuth = false

    init(
        base: any ReviewAuthSession,
        sharedDependencies: ReviewCoreDependencies,
        probeDependencies: ReviewCoreDependencies
    ) async throws {
        self.base = base
        fileSystem = sharedDependencies.fileSystem
        sharedAuthURL = sharedDependencies.paths.reviewAuthURL()
        probeAuthURL = probeDependencies.paths.reviewAuthURL()
        originalSharedAuthData = try? sharedDependencies.fileSystem.readData(sharedAuthURL)
        originalSharedAuthEmail = extractedAuthSnapshotEmail(from: originalSharedAuthData)
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        let response = try await base.readAccount(refreshToken: refreshToken)
        if case .chatGPT(let email, _)? = response.account,
           let email = email.nilIfEmpty
        {
            let currentSharedAuthData = try? fileSystem.readData(sharedAuthURL)
            if currentSharedAuthData != nil,
               (
                   currentSharedAuthData != originalSharedAuthData
                       || originalSharedAuthEmail == email
               )
            {
                copySharedAuthToProbe()
            }
        } else if response.requiresOpenAIAuth {
            removeProbeAuth()
        }
        return response
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        try await base.startLogin(params)
    }

    func cancelLogin(loginID: String) async throws {
        try await base.cancelLogin(loginID: loginID)
    }

    func logout() async throws {
        try await base.logout()
        removeProbeAuth()
        restoreSharedAuthIfNeeded()
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        await base.notificationStream()
    }

    func close() async {
        await base.close()
        restoreSharedAuthIfNeeded()
    }

    private func copySharedAuthToProbe() {
        guard let data = try? fileSystem.readData(sharedAuthURL) else {
            return
        }
        try? fileSystem.createDirectory(probeAuthURL.deletingLastPathComponent(), true)
        try? fileSystem.writeData(data, probeAuthURL, [.atomic])
    }

    private func removeProbeAuth() {
        try? fileSystem.removeItem(probeAuthURL)
    }

    private func restoreSharedAuthIfNeeded() {
        guard restoredSharedAuth == false else {
            return
        }
        restoredSharedAuth = true
        if let originalSharedAuthData {
            try? fileSystem.createDirectory(sharedAuthURL.deletingLastPathComponent(), true)
            try? fileSystem.writeData(originalSharedAuthData, sharedAuthURL, [.atomic])
        } else {
            try? fileSystem.removeItem(sharedAuthURL)
        }
    }
}

private func makeReviewAuthToken(payload: [String: Any]) -> String {
    let header = ["alg": "none", "typ": "JWT"]
    let headerData = try? JSONSerialization.data(withJSONObject: header)
    let payloadData = try? JSONSerialization.data(withJSONObject: payload)
    return "\(makeReviewAuthTokenComponent(headerData ?? Data())).\(makeReviewAuthTokenComponent(payloadData ?? Data()))."
}

private func makeReviewAuthTokenComponent(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func extractedAuthSnapshotEmail(from authData: Data?) -> String? {
    guard let authData,
          let object = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any],
          let idToken = tokens["id_token"] as? String
    else {
        return nil
    }
    let components = idToken.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2,
          let payloadData = decodeBase64URL(String(components[1])),
          let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
          let email = payloadObject["email"] as? String
    else {
        return nil
    }
    return email.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private func decodeBase64URL(_ value: String) -> Data? {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder != 0 {
        normalized.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: normalized)
}

typealias ReviewMonitorWebAuthenticationSessionFactory = @MainActor @Sendable (
    URL,
    String,
    ReviewMonitorNativeAuthenticationConfiguration.BrowserSessionPolicy,
    @escaping @MainActor @Sendable () -> ASPresentationAnchor?
) async throws -> ReviewMonitorWebAuthenticationSession

@MainActor
final class ReviewMonitorWebAuthenticationSession: Sendable {
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor

        init(anchor: ASPresentationAnchor) {
            self.anchor = anchor
        }

        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            return anchor
        }
    }

    private var session: ASWebAuthenticationSession?
    private var provider: PresentationContextProvider?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, ReviewAuthError>?
    private let onWaitStart: (@Sendable () async -> Void)?
    private let onCancel: (@Sendable () async -> Void)?

    init(
        onWaitStart: (@Sendable () async -> Void)? = nil,
        onCancel: (@Sendable () async -> Void)? = nil
    ) {
        self.onWaitStart = onWaitStart
        self.onCancel = onCancel
    }

    static func startSystem(
        using url: URL,
        callbackScheme: String,
        browserSessionPolicy: ReviewMonitorNativeAuthenticationConfiguration.BrowserSessionPolicy,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> ReviewMonitorWebAuthenticationSession {
        guard let anchor = presentationAnchorProvider() else {
            throw ReviewAuthError.loginFailed("Unable to present authentication session.")
        }

        let activeSession = ReviewMonitorWebAuthenticationSession()
        let provider = PresentationContextProvider(anchor: anchor)
        let session = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(callbackScheme),
            completionHandler: makeReviewMonitorWebAuthenticationCompletionHandler(activeSession)
        )
        session.prefersEphemeralWebBrowserSession = {
            switch browserSessionPolicy {
            case .ephemeral:
                true
            }
        }()
        session.presentationContextProvider = provider

        activeSession.install(
            session: session,
            provider: provider
        )
        let didStart = session.start()
        guard didStart else {
            activeSession.finish(
                callbackURL: nil,
                error: .loginFailed("Unable to start authentication session.")
            )
            throw ReviewAuthError.loginFailed("Unable to start authentication session.")
        }

        return activeSession
    }

    func waitForCallbackURL() async throws -> URL {
        await onWaitStart?()
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
        }
    }

    func cancel() async {
        await onCancel?()
        session?.cancel()
    }

    func finish(callbackURL: URL?, error: ReviewAuthError?) {
        guard result == nil else {
            return
        }
        let terminalResult: Result<URL, ReviewAuthError>
        if let callbackURL {
            terminalResult = .success(callbackURL)
        } else if let error {
            terminalResult = .failure(error)
        } else {
            terminalResult = .failure(.cancelled)
        }
        result = terminalResult
        session = nil
        provider = nil
        continuation?.resume(with: terminalResult)
        continuation = nil
    }

    func finishForTesting(_ result: Result<URL, ReviewAuthError>) {
        switch result {
        case .success(let callbackURL):
            finish(callbackURL: callbackURL, error: nil)
        case .failure(let error):
            finish(callbackURL: nil, error: error)
        }
    }

    private func install(
        session: ASWebAuthenticationSession,
        provider: PresentationContextProvider
    ) {
        self.session = session
        self.provider = provider
    }
}

private func mapAuthenticationError(_ error: Error?) -> ReviewAuthError? {
    guard let error else {
        return nil
    }
    if let reviewAuthError = error as? ReviewAuthError {
        return reviewAuthError
    }
    let nsError = error as NSError
    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
       nsError.code == 1 {
        return .cancelled
    }
    return .loginFailed(error.localizedDescription)
}

private func makeReviewMonitorWebAuthenticationCompletionHandler(
    _ activeSession: ReviewMonitorWebAuthenticationSession
) -> @Sendable (URL?, Error?) -> Void {
    { [weak activeSession] callbackURL, error in
        let mappedError = mapAuthenticationError(error)
        Task { @MainActor [weak activeSession] in
            activeSession?.finish(callbackURL: callbackURL, error: mappedError)
        }
    }
}

actor NativeWebAuthenticationReviewSession: ReviewAuthSession {
    private enum NotificationTerminalState {
        case finished
        case failed(any Error)
    }

    private let sharedSession: SharedAppServerReviewAuthSession
    private let nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration
    private let webAuthenticationSessionFactory: ReviewMonitorWebAuthenticationSessionFactory
    private var notificationSubscribers: [UUID: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation] = [:]
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var notificationTerminalState: NotificationTerminalState?
    private var relayTask: Task<Void, Never>?
    private var activeLoginID: String?
    private var activeAuthenticationSession: ReviewMonitorWebAuthenticationSession?
    private var authenticationTask: Task<Void, Never>?
    private var isClosed = false
    private let onClose: (@Sendable () async -> Void)?

    init(
        sharedSession: SharedAppServerReviewAuthSession,
        nativeAuthenticationConfiguration: ReviewMonitorNativeAuthenticationConfiguration,
        webAuthenticationSessionFactory: @escaping ReviewMonitorWebAuthenticationSessionFactory,
        onClose: (@Sendable () async -> Void)? = nil
    ) {
        self.sharedSession = sharedSession
        self.nativeAuthenticationConfiguration = nativeAuthenticationConfiguration
        self.webAuthenticationSessionFactory = webAuthenticationSessionFactory
        self.onClose = onClose
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        try await sharedSession.readAccount(refreshToken: refreshToken)
    }

    func startLogin(_: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        try throwIfClosed()
        try await startRelayIfNeeded()

        let response = try await sharedSession.startLogin(
            .chatGPT(
                nativeWebAuthentication: .init(
                    callbackURLScheme: nativeAuthenticationConfiguration.callbackScheme
                )
            )
        )

        guard case .chatGPT(let loginID, let authURL, let nativeWebAuthentication) = response,
              let authURL = URL(string: authURL)
        else {
            throw ReviewAuthError.loginFailed("Authentication did not provide a valid authorization URL.")
        }
        if isClosed {
            do {
                try await sharedSession.cancelLogin(loginID: loginID)
            } catch {
            }
            throw ReviewAuthError.cancelled
        }
        let callbackScheme = nativeWebAuthentication?.callbackURLScheme.nilIfEmpty
            ?? nativeAuthenticationConfiguration.callbackScheme
        if let serverCallbackScheme = nativeWebAuthentication?.callbackURLScheme.nilIfEmpty,
           serverCallbackScheme != nativeAuthenticationConfiguration.callbackScheme {
            do {
                try await sharedSession.cancelLogin(loginID: loginID)
            } catch {
            }
            throw ReviewAuthError.loginFailed(
                "Authentication callback is misconfigured. Update the app-server and try again."
            )
        }

        activeLoginID = loginID
        let activeAuthenticationSession: ReviewMonitorWebAuthenticationSession
        do {
            activeAuthenticationSession = try await webAuthenticationSessionFactory(
                authURL,
                callbackScheme,
                nativeAuthenticationConfiguration.browserSessionPolicy,
                nativeAuthenticationConfiguration.presentationAnchorProvider
            )
        } catch {
            activeLoginID = nil
            do {
                try await sharedSession.cancelLogin(loginID: loginID)
            } catch {
            }
            throw error
        }
        guard activeLoginID == loginID, isClosed == false else {
            await activeAuthenticationSession.cancel()
            if activeLoginID == loginID {
                activeLoginID = nil
            }
            throw ReviewAuthError.cancelled
        }
        self.activeAuthenticationSession = activeAuthenticationSession
        authenticationTask = Task {
            do {
                let callbackURL = try await activeAuthenticationSession.waitForCallbackURL()
                try await self.completeLogin(loginID: loginID, callbackURL: callbackURL)
            } catch ReviewAuthError.cancelled {
                await self.handleAuthenticationCancellation(for: loginID)
            } catch {
                await self.handleAuthenticationFailure(for: loginID, error: error)
            }
        }

        return response
    }

    func cancelLogin(loginID: String) async throws {
        guard activeLoginID == loginID else {
            return
        }
        let activeAuthenticationSession = self.activeAuthenticationSession
        self.activeAuthenticationSession = nil
        authenticationTask?.cancel()
        await activeAuthenticationSession?.cancel()
        activeLoginID = nil
        finishNotificationSubscribers(failing: nil, discardBufferedNotifications: true)
        authenticationTask = nil
        do {
            try await sharedSession.cancelLogin(loginID: loginID)
        } catch {
        }
    }

    func logout() async throws {
        try await sharedSession.logout()
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        if let notificationTerminalState {
            for notification in bufferedNotifications {
                continuation.yield(notification)
            }
            finishNotificationContinuation(continuation, with: notificationTerminalState)
            return stream
        }

        let subscriberID = UUID()
        notificationSubscribers[subscriberID] = continuation
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
        continuation.onTermination = { _ in
            Task {
                await self.removeNotificationSubscriber(id: subscriberID)
            }
        }
        return stream
    }

    func waitForAuthenticationTaskCompletion() async {
        if let authenticationTask {
            await authenticationTask.value
        }
    }

    func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        let activeLoginIDToCancel = activeLoginID
        let activeAuthenticationSession = self.activeAuthenticationSession
        activeLoginID = nil
        self.activeAuthenticationSession = nil
        authenticationTask?.cancel()
        finishNotificationSubscribers(failing: nil, discardBufferedNotifications: true)
        authenticationTask = nil
        await activeAuthenticationSession?.cancel()
        if let activeLoginIDToCancel {
            do {
                try await sharedSession.cancelLogin(loginID: activeLoginIDToCancel)
            } catch {
            }
        }
        relayTask?.cancel()
        relayTask = nil
        await sharedSession.close()
        if let onClose {
            await onClose()
        }
    }

    private func startRelayIfNeeded() async throws {
        guard relayTask == nil else {
            return
        }
        let notificationStream = await sharedSession.notificationStream()
        relayTask = Task {
            do {
                for try await notification in notificationStream {
                    await self.handleNotification(notification)
                }
                self.finishRelay(error: nil)
            } catch {
                self.finishRelay(error: error)
            }
        }
    }

    private func handleNotification(_ notification: AppServerServerNotification) async {
        guard notificationTerminalState == nil else {
            return
        }
        bufferedNotifications.append(notification)
        switch notification {
        case .accountLoginCompleted(let completed):
            let completedLoginID = completed.loginID?.nilIfEmpty
            if completedLoginID == nil || completedLoginID == activeLoginID {
                let activeAuthenticationSession = self.activeAuthenticationSession
                let authenticationTask = self.authenticationTask
                activeLoginID = nil
                self.activeAuthenticationSession = nil
                self.authenticationTask = nil
                authenticationTask?.cancel()
                await activeAuthenticationSession?.cancel()
            }
        default:
            break
        }
        for continuation in notificationSubscribers.values {
            continuation.yield(notification)
        }
    }

    private func completeLogin(loginID: String, callbackURL: URL) async throws {
        guard activeLoginID == loginID else {
            return
        }
        do {
            try await sharedSession.completeLogin(
                loginID: loginID,
                callbackURL: callbackURL.absoluteString
            )
            try await ensureAuthenticationCompletionDelivered(loginID: loginID)
        } catch let error as AppServerResponseError where error.isUnsupportedMethod {
            throw ReviewAuthError.loginFailed(
                "Authentication completion is unavailable. Update the app-server and try again."
            )
        }
    }

    private func ensureAuthenticationCompletionDelivered(loginID: String) async throws {
        if hasBufferedAuthenticationCompletion(loginID: loginID) {
            return
        }

        let shouldSynthesizeAccountUpdate = hasBufferedAuthenticationUpdate == false
        let synthesizedPlanType: String?
        if shouldSynthesizeAccountUpdate,
           let account = try? await sharedSession.readAccount(refreshToken: true),
           case .chatGPT(_, let planType) = account.account {
            synthesizedPlanType = planType
        } else {
            synthesizedPlanType = nil
        }

        if hasBufferedAuthenticationCompletion(loginID: loginID) {
            return
        }

        if hasBufferedAuthenticationUpdate == false,
           let synthesizedPlanType {
            await handleNotification(
                .accountUpdated(
                    try makeSyntheticAccountUpdatedNotification(planType: synthesizedPlanType)
                )
            )
        }

        if hasBufferedAuthenticationCompletion(loginID: loginID) {
            return
        }

        await handleNotification(
            .accountLoginCompleted(
                try makeSyntheticAccountLoginCompletedNotification(loginID: loginID)
            )
        )
    }

    private var hasBufferedAuthenticationUpdate: Bool {
        bufferedNotifications.contains { notification in
            if case .accountUpdated = notification {
                return true
            }
            return false
        }
    }

    private func hasBufferedAuthenticationCompletion(loginID: String) -> Bool {
        bufferedNotifications.contains { notification in
            guard case .accountLoginCompleted(let completed) = notification else {
                return false
            }
            guard let completedLoginID = completed.loginID?.nilIfEmpty else {
                return true
            }
            return completedLoginID == loginID
        }
    }

    private func makeSyntheticAccountUpdatedNotification(
        planType: String?
    ) throws -> AppServerAccountUpdatedNotification {
        var payload: [String: Any] = [
            "authMode": "chatgpt",
        ]
        payload["planType"] = planType
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(AppServerAccountUpdatedNotification.self, from: data)
    }

    private func makeSyntheticAccountLoginCompletedNotification(
        loginID: String
    ) throws -> AppServerAccountLoginCompletedNotification {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "error": NSNull(),
                "loginId": loginID,
                "success": true,
            ]
        )
        return try JSONDecoder().decode(AppServerAccountLoginCompletedNotification.self, from: data)
    }

    private func handleAuthenticationCancellation(for loginID: String) async {
        guard activeLoginID == loginID else {
            return
        }
        activeLoginID = nil
        activeAuthenticationSession = nil
        finishNotificationSubscribers(failing: nil, discardBufferedNotifications: true)
        do {
            try await sharedSession.cancelLogin(loginID: loginID)
        } catch {
        }
        authenticationTask = nil
    }

    private func handleAuthenticationFailure(for loginID: String, error: Error) async {
        guard activeLoginID == loginID else {
            return
        }
        activeLoginID = nil
        activeAuthenticationSession = nil
        finishNotificationSubscribers(
            failing: error as? ReviewAuthError ?? ReviewAuthError.loginFailed(error.localizedDescription)
        )
        do {
            try await sharedSession.cancelLogin(loginID: loginID)
        } catch {
        }
        authenticationTask = nil
    }

    private func finishRelay(error: Error?) {
        relayTask = nil
        if let error {
            finishNotificationSubscribers(failing: error)
        } else {
            finishNotificationSubscribers(failing: nil)
        }
    }

    private func removeNotificationSubscriber(id: UUID) {
        notificationSubscribers.removeValue(forKey: id)
    }

    private func finishNotificationSubscribers(
        failing error: Error?,
        discardBufferedNotifications: Bool = false
    ) {
        if notificationTerminalState == nil {
            notificationTerminalState = makeNotificationTerminalState(failing: error)
        }
        if discardBufferedNotifications {
            bufferedNotifications.removeAll(keepingCapacity: false)
        }
        let subscribers = notificationSubscribers.values
        notificationSubscribers.removeAll()
        for continuation in subscribers {
            finishNotificationContinuation(continuation, with: notificationTerminalState!)
        }
    }

    private func throwIfClosed() throws {
        if isClosed {
            throw ReviewAuthError.loginFailed("Authentication session is closed.")
        }
    }

    private func finishNotificationContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation,
        with terminalState: NotificationTerminalState
    ) {
        switch terminalState {
        case .finished:
            continuation.finish()
        case .failed(let error):
            continuation.finish(throwing: error)
        }
    }

    private func makeNotificationTerminalState(failing error: Error?) -> NotificationTerminalState {
        guard let error else {
            return .finished
        }
        if error is CancellationError {
            return .finished
        }
        return .failed(error)
    }
}

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

@MainActor
package final class ReviewMonitorServerRuntime: ReviewMonitorServerCoordinating, ReviewMonitorSettingsBackend, ReviewMonitorAuthRuntimeManaging {
    private struct DeferredAddAccountRuntimeEffect {
        var accountKey: String
        var runtimeGeneration: Int
    }

    let configuration: ReviewServerConfiguration
    let appServerManager: any AppServerManaging
    let accountRegistryStore: ReviewAccountRegistryStore
    let sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
    let loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)?
    let deferStartupAuthRefreshUntilPrepared: Bool
    let shouldAutoStartEmbeddedServer: Bool
    let initialAccount: CodexAccount?
    let initialAccounts: [CodexAccount]
    let initialActiveAccountKey: String?
    let rateLimitObservationClock: any ReviewClock
    let rateLimitStaleRefreshInterval: Duration
    let inactiveRateLimitRefreshInterval: Duration
    weak var authOrchestrator: ReviewMonitorAuthOrchestrator?
    weak var settingsService: ReviewMonitorSettingsService?
    var executionCoordinator: ReviewExecutionCoordinator?
    lazy var liveSharedAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { [weak self, appServerManager, configuration] environment in
        let makeCLISession = {
            CLIReviewAuthSession(
                configuration: .init(
                    codexCommand: configuration.codexCommand,
                    environment: environment,
                    coreDependencies: configuration.coreDependencies.replacingEnvironment(environment)
                )
            )
        }
        let shouldUseSharedRuntime = await MainActor.run {
            self?.authRuntimeState.serverIsRunning ?? false
        }
        let shouldProbeInjectedManager = (appServerManager is AppServerSupervisor) == false
        guard shouldUseSharedRuntime || shouldProbeInjectedManager else {
            return makeCLISession()
        }
        do {
            let transport = try await appServerManager.checkoutAuthTransport()
            return SharedAppServerReviewAuthSession(transport: transport)
        } catch {
            guard shouldUseSharedRuntime else {
                return makeCLISession()
            }
            throw error
        }
    }
    lazy var liveCLIAuthSessionFactory: @Sendable ([String: String]) async throws -> any ReviewAuthSession = { [configuration] environment in
        CLIReviewAuthSession(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: environment,
                coreDependencies: configuration.coreDependencies.replacingEnvironment(environment)
            )
        )
    }

    private var server: ReviewMCPHTTPServer?
    private var waitTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupTaskID: UInt64?
    private var nextStartupTaskID: UInt64 = 0
    private var appServerRuntimeGeneration = 0
    private var deferredAddAccountRuntimeEffect: DeferredAddAccountRuntimeEffect?
    private var deferredAddAccountRuntimeReconcileTask: Task<Void, Never>?
    private weak var attachedStore: CodexReviewStore?
    private var observedHasRunningJobs: Bool?
    private let observationScope = ObservationScope()
    private var discoveryFileURL: URL {
        configuration.coreDependencies.paths.discoveryFileURL()
    }
    private var runtimeStateFileURL: URL {
        configuration.coreDependencies.paths.runtimeStateFileURL()
    }
    private var discoveryClient: ReviewDiscoveryClient {
        ReviewDiscoveryClient(dependencies: configuration.coreDependencies)
    }
    private var runtimeStateClient: ReviewRuntimeStateClient {
        ReviewRuntimeStateClient(dependencies: configuration.coreDependencies)
    }
    private var localConfigClient: ReviewLocalConfigClient {
        ReviewLocalConfigClient(dependencies: configuration.coreDependencies)
    }
    private var codexHomeURL: URL {
        configuration.coreDependencies.paths.codexHomeURL()
    }
    var currentServer: ReviewMCPHTTPServer? {
        server
    }
    package var authRuntimeState: CodexAuthRuntimeState {
        .init(
            serverIsRunning: server != nil,
            runtimeGeneration: appServerRuntimeGeneration
        )
    }

    package func resolveAddAccountRuntimeEffect(
        accountKey: String,
        runtimeGeneration: Int
    ) -> CodexAuthRuntimeEffect {
        if attachedStore?.hasRunningJobs ?? false {
            return .deferRecycleUntilJobsDrain(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
        }
        return .recycleNow(
            accountKey: accountKey,
            runtimeGeneration: runtimeGeneration
        )
    }

    package func applyAddAccountRuntimeEffect(
        _ effect: CodexAuthRuntimeEffect,
        auth: CodexReviewAuthModel
    ) async {
        switch effect {
        case .none:
            scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
        case .deferRecycleUntilJobsDrain(let accountKey, let runtimeGeneration):
            cancelDeferredAddAccountRuntimeReconcileTask()
            deferredAddAccountRuntimeEffect = .init(
                accountKey: accountKey,
                runtimeGeneration: runtimeGeneration
            )
            scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
        case .recycleNow(let accountKey, let runtimeGeneration):
            cancelDeferredAddAccountRuntimeReconcileTask()
            guard let store = attachedStore,
                  authRuntimeState.serverIsRunning,
                  authRuntimeState.runtimeGeneration == runtimeGeneration,
                  auth.selectedAccount?.accountKey == accountKey
            else {
                deferredAddAccountRuntimeEffect = nil
                return
            }
            guard store.hasRunningJobs == false else {
                deferredAddAccountRuntimeEffect = .init(
                    accountKey: accountKey,
                    runtimeGeneration: runtimeGeneration
                )
                scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
                return
            }
            deferredAddAccountRuntimeEffect = nil
            await recycleSharedAppServerAfterAuthChange()
            await authOrchestrator?.reconcileAuthenticatedSession(
                auth: store.auth,
                serverIsRunning: authRuntimeState.serverIsRunning,
                runtimeGeneration: authRuntimeState.runtimeGeneration
            )
            await reconcileDeferredAddAccountRuntimeEffectIfNeeded(store: store)
        }
    }

    fileprivate func scheduleDeferredAddAccountRuntimeReconciliationIfNeeded() {
        guard deferredAddAccountRuntimeEffect != nil,
              deferredAddAccountRuntimeReconcileTask == nil,
              let store = attachedStore,
              authRuntimeState.serverIsRunning,
              store.hasRunningJobs == false
        else {
            return
        }
        deferredAddAccountRuntimeReconcileTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            defer {
                self.deferredAddAccountRuntimeReconcileTask = nil
            }
            await self.reconcileDeferredAddAccountRuntimeEffectIfNeeded(store: store)
        }
    }

    private func cancelDeferredAddAccountRuntimeReconcileTask() {
        deferredAddAccountRuntimeReconcileTask?.cancel()
        deferredAddAccountRuntimeReconcileTask = nil
    }

    private func reconcileDeferredAddAccountRuntimeEffectIfNeeded(
        store: CodexReviewStore
    ) async {
        guard let deferredAddAccountRuntimeEffect else {
            return
        }
        guard authRuntimeState.serverIsRunning,
              authRuntimeState.runtimeGeneration == deferredAddAccountRuntimeEffect.runtimeGeneration,
              store.auth.selectedAccount?.accountKey == deferredAddAccountRuntimeEffect.accountKey
        else {
            self.deferredAddAccountRuntimeEffect = nil
            return
        }
        guard store.hasRunningJobs == false else {
            return
        }
        self.deferredAddAccountRuntimeEffect = nil
        await recycleSharedAppServerAfterAuthChange()
        await authOrchestrator?.reconcileAuthenticatedSession(
            auth: store.auth,
            serverIsRunning: authRuntimeState.serverIsRunning,
            runtimeGeneration: authRuntimeState.runtimeGeneration
        )
    }

    private func reconcileAuthRuntime(
        store: CodexReviewStore,
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        if serverIsRunning {
            await reconcileDeferredAddAccountRuntimeEffectIfNeeded(store: store)
        } else {
            cancelDeferredAddAccountRuntimeReconcileTask()
            deferredAddAccountRuntimeEffect = nil
        }
        await authOrchestrator?.reconcileAuthenticatedSession(
            auth: store.auth,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }

    package var initialSettingsSnapshot: CodexReviewSettingsSnapshot {
        let localConfig = (try? localConfigClient.load()) ?? .init()
        let fallbackConfig = loadFallbackAppServerConfig(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsServiceTier = activeProfileClearsServiceTier(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let displayedOverrides = resolveDisplayedSettingsOverrides(
            localConfig: localConfig,
            resolvedConfig: fallbackConfig,
            profileClearsReasoningEffort: profileClearsReasoningEffort,
            profileClearsServiceTier: profileClearsServiceTier
        )
        return .init(
            model: resolveReviewModelOverride(
                localConfig: localConfig,
                resolvedConfig: fallbackConfig,
                profileClearsReviewModel: profileClearsReviewModel
            ),
            fallbackModel: fallbackConfig.model?.nilIfEmpty,
            reasoningEffort: displayedOverrides.reasoningEffort,
            serviceTier: displayedOverrides.serviceTier,
            models: []
        )
    }

    package var isActive: Bool {
        server != nil || waitTask != nil || startupTask != nil
    }

    init(
        configuration: ReviewServerConfiguration,
        appServerManager: (any AppServerManaging)? = nil,
        sharedAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        loginAuthSessionFactory: (@Sendable ([String: String]) async throws -> any ReviewAuthSession)? = nil,
        rateLimitObservationClock: any ReviewClock = ContinuousClock(),
        rateLimitStaleRefreshInterval: Duration = .seconds(60),
        inactiveRateLimitRefreshInterval: Duration = .seconds(15 * 60),
        deferStartupAuthRefreshUntilPrepared: Bool = false
    ) {
        self.configuration = configuration
        self.appServerManager = appServerManager ?? AppServerSupervisor(
            configuration: .init(
                codexCommand: configuration.codexCommand,
                environment: configuration.environment,
                clock: configuration.coreDependencies.clock,
                coreDependencies: configuration.coreDependencies
            )
        )
        self.accountRegistryStore = ReviewAccountRegistryStore(coreDependencies: configuration.coreDependencies)
        self.sharedAuthSessionFactory = sharedAuthSessionFactory
        self.loginAuthSessionFactory = loginAuthSessionFactory
        self.rateLimitObservationClock = rateLimitObservationClock
        self.rateLimitStaleRefreshInterval = rateLimitStaleRefreshInterval
        self.inactiveRateLimitRefreshInterval = inactiveRateLimitRefreshInterval
        self.deferStartupAuthRefreshUntilPrepared = deferStartupAuthRefreshUntilPrepared
        self.shouldAutoStartEmbeddedServer = configuration.shouldAutoStartEmbeddedServer
        var seededAccounts = loadRegisteredReviewAccounts(dependencies: configuration.coreDependencies)
        let sharedInitialAccount = loadSharedReviewAccount(dependencies: configuration.coreDependencies)
        var shouldClearInitialSelection = false
        if let sharedInitialAccount {
            let matchingSavedAccount = seededAccounts.accounts.first {
                $0.accountKey == sharedInitialAccount.accountKey
            }
            let activeSavedAccount = seededAccounts.activeAccountKey.flatMap { activeAccountKey in
                seededAccounts.accounts.first(where: { $0.accountKey == activeAccountKey })
            }
            if matchingSavedAccount == nil || activeSavedAccount?.accountKey != matchingSavedAccount?.accountKey {
                do {
                    try accountRegistryStore.saveSharedAuthAsSavedAccount(
                        makeActive: true
                    )
                } catch {
                    shouldClearInitialSelection = false
                }
                seededAccounts = loadRegisteredReviewAccounts(dependencies: configuration.coreDependencies)
            }
        }

        let initialAccounts = seededAccounts.accounts.map(makeCodexAccount)

        let resolvedInitialAccount: CodexAccount? = {
            guard shouldClearInitialSelection == false else {
                return nil
            }
            if let sharedInitialAccount,
               let persistedSharedAccount = initialAccounts.first(where: {
                   $0.accountKey == sharedInitialAccount.accountKey
               })
            {
                return persistedSharedAccount
            }
            if let sharedInitialAccount {
                return sharedInitialAccount
            }
            if let activeAccountKey = seededAccounts.activeAccountKey {
                return initialAccounts
                    .first(where: { $0.accountKey == activeAccountKey })
            }
            return nil
        }()

        let resolvedInitialActiveAccountKey: String? = {
            guard shouldClearInitialSelection == false else {
                return nil
            }
            if let sharedInitialAccount,
               initialAccounts.contains(where: { $0.accountKey == sharedInitialAccount.accountKey })
            {
                return sharedInitialAccount.accountKey
            }
            return seededAccounts.activeAccountKey
        }()

        self.initialAccounts = initialAccounts
        self.initialActiveAccountKey = resolvedInitialActiveAccountKey
        self.initialAccount = resolvedInitialAccount
    }

    package func attachStore(_ store: CodexReviewStore) {
        attachedStore = store
        observedHasRunningJobs = store.hasRunningJobs
        observationScope.cancelAll()
        observeRunningJobs()
    }

    private func observeRunningJobs() {
        guard let attachedStore else {
            return
        }
        attachedStore.observe(\.hasRunningJobs) { [weak self] hasRunningJobs in
            guard let self else {
                return
            }
            guard hasRunningJobs != self.observedHasRunningJobs else {
                return
            }
            self.observedHasRunningJobs = hasRunningJobs
            self.scheduleDeferredAddAccountRuntimeReconciliationIfNeeded()
        }
        .store(in: observationScope)
    }

    package func start(
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        if deferStartupAuthRefreshUntilPrepared == false {
            authOrchestrator?.startStartupRefresh(auth: store.auth)
        }
        let startupID = makeStartupTaskID()
        let task = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            await self.performStartup(
                startupID: startupID,
                store: store,
                forceRestartIfNeeded: forceRestartIfNeeded
            )
        }
        startupTaskID = startupID
        startupTask = task
        await task.value
        if startupTaskID == startupID {
            startupTask = nil
            startupTaskID = nil
        }
    }

    package func stop(store: CodexReviewStore) async {
        let startupTask = self.startupTask
        self.startupTask = nil
        startupTaskID = nil
        startupTask?.cancel()
        authOrchestrator?.cancelStartupRefresh()
        if store.auth.isAuthenticating {
            await authOrchestrator?.cancelAuthentication(auth: store.auth)
        }
        await reconcileAuthRuntime(
            store: store,
            serverIsRunning: false,
            runtimeGeneration: appServerRuntimeGeneration
        )
        waitTask?.cancel()
        waitTask = nil
        await executionCoordinator?.shutdown(reason: "Review server stopped.", store: store)
        if let server {
            let endpointRecord = server.currentEndpointRecord()
            self.server = nil
            await server.stop()
            await appServerManager.shutdown()
            removeRuntimeState(endpointRecord: endpointRecord)
        } else {
            await appServerManager.shutdown()
        }
        await startupTask?.value
    }

    package func waitUntilStopped() async {
        if let startupTask {
            await startupTask.value
        }
        if let waitTask {
            await waitTask.value
        }
    }

    package func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        let transport = try await appServerManager.checkoutAuthTransport()
        let localConfig = (try? localConfigClient.load()) ?? .init()
        let fallbackConfig = loadFallbackAppServerConfig(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let configResponse: AppServerConfigReadResponse = try await transport.request(
            method: "config/read",
            params: AppServerConfigReadParams(
                cwd: nil,
                includeLayers: false
            ),
            responseType: AppServerConfigReadResponse.self
        )
        var models: [CodexReviewModelCatalogItem] = []
        var cursor: String?
        repeat {
            let modelResponse: AppServerModelListResponse = try await transport.request(
                method: "model/list",
                params: AppServerModelListParams(
                    cursor: cursor,
                    limit: nil,
                    includeHidden: true
                ),
                responseType: AppServerModelListResponse.self
            )
            models.append(contentsOf: modelResponse.data)
            cursor = modelResponse.nextCursor?.nilIfEmpty
        } while cursor != nil
        let effectiveConfig = mergeAppServerConfig(
            primary: configResponse.config,
            fallback: fallbackConfig
        )
        let profileClearsReviewModel = activeProfileClearsReviewModel(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsReasoningEffort = activeProfileClearsReasoningEffort(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let profileClearsServiceTier = activeProfileClearsServiceTier(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let displayedOverrides = resolveDisplayedSettingsOverrides(
            localConfig: localConfig,
            resolvedConfig: effectiveConfig,
            profileClearsReasoningEffort: profileClearsReasoningEffort,
            profileClearsServiceTier: profileClearsServiceTier
        )
        let modelOverride = resolveReviewModelOverride(
            localConfig: localConfig,
            resolvedConfig: effectiveConfig,
            profileClearsReviewModel: profileClearsReviewModel
        )

        return .init(
            model: modelOverride,
            fallbackModel: effectiveConfig.model?.nilIfEmpty,
            reasoningEffort: displayedOverrides.reasoningEffort,
            serviceTier: displayedOverrides.serviceTier,
            models: models
        )
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        let profile = loadActiveReviewProfile(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let localConfigPresence = try localConfigClient.loadPresence()
        let hasRootReviewModel = localConfigPresence.hasReviewModel
        let hasProfileReviewModelOverride = activeProfileHasReviewModelOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let writeModelAtRoot = profile == nil
            || (hasRootReviewModel && hasProfileReviewModelOverride == false)
        let hasRootReasoningEffort = localConfigPresence.hasModelReasoningEffort
        let hasProfileReasoningEffortOverride = activeProfileHasReasoningEffortOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let writeReasoningAtRoot = profile == nil
            || (hasRootReasoningEffort && hasProfileReasoningEffortOverride == false)
        let hasRootServiceTier = localConfigPresence.hasServiceTier
        let hasProfileServiceTierOverride = activeProfileHasServiceTierOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let writeServiceTierAtRoot = profile == nil
            || (hasRootServiceTier && hasProfileServiceTierOverride == false)
        var edits: [AppServerConfigEdit] = [
            .init(
                keyPath: settingsKeyPath(
                    "review_model",
                    profileKeyPath: profile?.keyPathPrefix,
                    forceRoot: writeModelAtRoot
                ),
                value: model.map(AppServerJSONValue.string) ?? .null,
                mergeStrategy: .replace
            ),
        ]
        if persistReasoningEffort {
            edits.append(
                .init(
                    keyPath: settingsKeyPath(
                        "model_reasoning_effort",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: writeReasoningAtRoot
                    ),
                    value: reasoningEffort.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                )
            )
        }
        if persistServiceTier {
            edits.append(
                .init(
                    keyPath: settingsKeyPath(
                        "service_tier",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: writeServiceTierAtRoot
                    ),
                    value: serviceTier.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                )
            )
        }
        try await writeSettings(edits: edits)
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        let profile = loadActiveReviewProfile(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let localConfigPresence = try localConfigClient.loadPresence()
        let hasRootReasoningEffort = localConfigPresence.hasModelReasoningEffort
        let hasProfileReasoningEffortOverride = activeProfileHasReasoningEffortOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let forceRoot = profile == nil
            || (hasRootReasoningEffort && hasProfileReasoningEffortOverride == false)
        try await writeSettings(
            edits: [
                .init(
                    keyPath: settingsKeyPath(
                        "model_reasoning_effort",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: forceRoot
                    ),
                    value: reasoningEffort.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                ),
            ]
        )
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        let profile = loadActiveReviewProfile(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let localConfigPresence = try localConfigClient.loadPresence()
        let hasRootServiceTier = localConfigPresence.hasServiceTier
        let hasProfileServiceTierOverride = activeProfileHasServiceTierOverride(
            environment: configuration.environment,
            codexHome: codexHomeURL
        )
        let forceRoot = profile == nil
            || (hasRootServiceTier && hasProfileServiceTierOverride == false)
        try await writeSettings(
            edits: [
                .init(
                    keyPath: settingsKeyPath(
                        "service_tier",
                        profileKeyPath: profile?.keyPathPrefix,
                        forceRoot: forceRoot
                    ),
                    value: serviceTier.map { .string($0.rawValue) } ?? .null,
                    mergeStrategy: .replace
                ),
            ]
        )
    }

    func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation,
        store: CodexReviewStore
    ) async throws {
        let job = try store.resolveJob(jobID: jobID, sessionID: sessionID)
        _ = try await store.cancelReview(
            selectedJobID: job.id,
            sessionID: sessionID,
            cancellation: cancellation
        )
    }

    private func makeServer(store: CodexReviewStore) -> ReviewMCPHTTPServer {
        ReviewMCPHTTPServer(
            configuration: configuration,
            startReview: { [weak store] sessionID, request in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.startReview(sessionID: sessionID, request: request)
            },
            readReview: { [weak store] sessionID, jobID in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try store.readReview(jobID: jobID, sessionID: sessionID)
            },
            listReviews: { [weak store] sessionID, cwd, statuses, limit in
                guard let store else {
                    return ReviewListResult(items: [])
                }
                return store.listReviews(
                    sessionID: sessionID,
                    cwd: cwd,
                    statuses: statuses,
                    limit: limit
                )
            },
            cancelReviewByID: { [weak store] sessionID, jobID, cancellation in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selectedJobID: jobID,
                    sessionID: sessionID,
                    cancellation: cancellation
                )
            },
            cancelReviewBySelector: { [weak store] sessionID, cwd, statuses, cancellation in
                guard let store else {
                    throw ReviewError.io("Review store is unavailable.")
                }
                return try await store.cancelReview(
                    selector: .init(
                        jobID: nil,
                        cwd: cwd,
                        statuses: statuses
                    ),
                    sessionID: sessionID,
                    cancellation: cancellation
                )
            },
            closeSession: { [weak store] sessionID in
                guard let store else {
                    return
                }
                await store.closeSession(sessionID, reason: "MCP session closed.")
            },
            hasActiveJobs: { [weak store] sessionID in
                guard let store else {
                    return false
                }
                return store.hasActiveJobs(for: sessionID)
            }
        )
    }

    private func performStartup(
        startupID: UInt64,
        store: CodexReviewStore,
        forceRestartIfNeeded: Bool
    ) async {
        let server = makeServer(store: store)
        do {
            let url = try await startServer(
                server,
                forceRestartIfNeeded: forceRestartIfNeeded
            )
            guard startupTaskID == startupID else {
                await server.stop()
                return
            }

            self.server = server
            runtimeStateClient.remove(at: runtimeStateFileURL)

            let appServerRuntimeState = try await appServerManager.prepare()
            guard startupTaskID == startupID, self.server === server else {
                await server.stop()
                return
            }

            writeRuntimeState(
                endpointRecord: server.currentEndpointRecord(),
                appServerRuntimeState: appServerRuntimeState
            )
            appServerRuntimeGeneration += 1
            store.transitionToRunning(serverURL: url)
            await reconcileAuthRuntime(
                store: store,
                serverIsRunning: true,
                runtimeGeneration: appServerRuntimeGeneration
            )
            if deferStartupAuthRefreshUntilPrepared {
                authOrchestrator?.startStartupRefresh(auth: store.auth)
            }
            observeServerLifecycle(server: server, store: store)
        } catch is CancellationError {
            await server.stop()
            guard startupTaskID == startupID else {
                return
            }
            await appServerManager.shutdown()
            self.server = nil
            await reconcileAuthRuntime(
                store: store,
                serverIsRunning: false,
                runtimeGeneration: appServerRuntimeGeneration
            )
        } catch {
            await server.stop()
            guard startupTaskID == startupID else {
                return
            }
            await appServerManager.shutdown()
            self.server = nil
            await reconcileAuthRuntime(
                store: store,
                serverIsRunning: false,
                runtimeGeneration: appServerRuntimeGeneration
            )
            store.transitionToFailed(CodexReviewStore.errorMessage(from: error))
            if deferStartupAuthRefreshUntilPrepared {
                authOrchestrator?.startStartupRefresh(auth: store.auth)
            }
        }
    }

    private func makeStartupTaskID() -> UInt64 {
        nextStartupTaskID += 1
        return nextStartupTaskID
    }

    private func startServer(
        _ server: ReviewMCPHTTPServer,
        forceRestartIfNeeded: Bool
    ) async throws -> URL {
        do {
            return try await server.start()
        } catch {
            guard forceRestartIfNeeded,
                  isAddressInUse(error)
            else {
                throw error
            }
            try await replayAddressInUseCleanup()
            return try await server.start()
        }
    }

    private func replayAddressInUseCleanup() async throws {
        let runtimeState = runtimeStateClient.read(from: runtimeStateFileURL)
        if let endpointRecord = addressInUseCleanupRecord(runtimeState: runtimeState) {
            try await forceRestart(
                endpointRecord: endpointRecord,
                runtimeState: runtimeState
            )
            discoveryClient.removeIfOwned(
                pid: endpointRecord.pid,
                url: URL(string: endpointRecord.url),
                serverStartTime: endpointRecord.serverStartTime,
                at: discoveryFileURL
            )
            runtimeStateClient.removeIfOwned(
                serverPID: endpointRecord.pid,
                serverStartTime: endpointRecord.serverStartTime,
                at: runtimeStateFileURL
            )
        }
    }

    private func addressInUseCleanupRecord(
        runtimeState: ReviewRuntimeStateRecord?
    ) -> LiveEndpointRecord? {
        if let endpointRecord = discoveryClient.readPersisted(from: discoveryFileURL),
           discoveryMatchesListenAddress(
            endpointRecord,
            host: configuration.host,
            port: configuration.port
           )
        {
            return endpointRecord
        }

        guard let runtimeState,
              let url = discoveryClient.makeURL(
                host: configuration.host,
                port: configuration.port,
                endpointPath: configuration.endpoint
              )
        else {
            return nil
        }

        return LiveEndpointRecord(
            url: url.absoluteString,
            host: configuration.host,
            port: configuration.port,
            pid: runtimeState.serverPID,
            serverStartTime: runtimeState.serverStartTime,
            updatedAt: runtimeState.updatedAt,
            executableName: nil
        )
    }

    private func observeServerLifecycle(
        server: ReviewMCPHTTPServer,
        store: CodexReviewStore
    ) {
        waitTask?.cancel()
        waitTask = Task { @MainActor [weak self, weak store] in
            do {
                try await server.waitUntilShutdown()
                guard let self, let store, self.server === server else {
                    return
                }
                await self.executionCoordinator?.shutdown(reason: "Review server stopped.", store: store)
                let endpointRecord = server.currentEndpointRecord()
                await server.stop()
                await self.appServerManager.shutdown()
                self.removeRuntimeState(endpointRecord: endpointRecord)
                self.server = nil
                self.authOrchestrator?.cancelStartupRefresh()
                await reconcileAuthRuntime(
                    store: store,
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToStopped()
            } catch is CancellationError {
            } catch {
                guard let self, let store, self.server === server else {
                    return
                }
                await self.executionCoordinator?.shutdown(reason: "Review server failed.", store: store)
                let endpointRecord = server.currentEndpointRecord()
                await server.stop()
                await self.appServerManager.shutdown()
                self.removeRuntimeState(endpointRecord: endpointRecord)
                self.server = nil
                self.authOrchestrator?.cancelStartupRefresh()
                await reconcileAuthRuntime(
                    store: store,
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: true
                )
            }
        }
    }

    package func cancelRunningJobs(reason: String) async throws {
        guard let store = attachedStore else {
            return
        }
        do {
            try await store.cancelAllRunningJobs(reason: reason)
        } catch {
            store.terminateAllRunningJobsLocally(
                reason: reason,
                failureMessage: error.localizedDescription
            )
            throw error
        }
    }

    package func recycleSharedAppServerAfterAuthChange() async {
        guard let server else {
            return
        }

        await appServerManager.shutdown()
        do {
            let runtimeState = try await appServerManager.prepare()
            writeRuntimeState(
                endpointRecord: server.currentEndpointRecord(),
                appServerRuntimeState: runtimeState
            )
            appServerRuntimeGeneration += 1
            if let store = attachedStore {
                await settingsService?.refreshIfRunning(serverState: store.serverState)
            }
        } catch {
            let endpointRecord = server.currentEndpointRecord()
            removeRuntimeState(endpointRecord: endpointRecord)
            await server.stop()
            self.server = nil
            if let store = attachedStore {
                await self.executionCoordinator?.shutdown(reason: "Review server failed.", store: store)
                store.terminateAllRunningJobsLocally(
                    reason: "Review server failed.",
                    failureMessage: CodexReviewStore.errorMessage(from: error)
                )
                authOrchestrator?.cancelStartupRefresh()
                await reconcileAuthRuntime(
                    store: store,
                    serverIsRunning: false,
                    runtimeGeneration: self.appServerRuntimeGeneration
                )
                store.transitionToFailed(
                    CodexReviewStore.errorMessage(from: error),
                    resetJobs: false
                )
            }
        }
    }

    fileprivate func writeRuntimeState(
        endpointRecord: LiveEndpointRecord?,
        appServerRuntimeState: AppServerRuntimeState
    ) {
        guard let endpointRecord else {
            return
        }
        let runtimeState = ReviewRuntimeStateRecord(
            serverPID: endpointRecord.pid,
            serverStartTime: endpointRecord.serverStartTime,
            appServerPID: appServerRuntimeState.pid,
            appServerStartTime: appServerRuntimeState.startTime,
            appServerProcessGroupLeaderPID: appServerRuntimeState.processGroupLeaderPID,
            appServerProcessGroupLeaderStartTime: appServerRuntimeState.processGroupLeaderStartTime,
            updatedAt: configuration.coreDependencies.dateNow()
        )
        try? runtimeStateClient.write(runtimeState, to: runtimeStateFileURL)
    }

    private func removeRuntimeState(endpointRecord: LiveEndpointRecord?) {
        guard let endpointRecord else {
            return
        }
        runtimeStateClient.removeIfOwned(
            serverPID: endpointRecord.pid,
            serverStartTime: endpointRecord.serverStartTime,
            at: runtimeStateFileURL
        )
    }

    private func writeSettings(
        edits: [AppServerConfigEdit]
    ) async throws {
        let transport = try await appServerManager.checkoutAuthTransport()
        let _: AppServerConfigWriteResponse = try await transport.request(
            method: "config/batchWrite",
            params: AppServerConfigBatchWriteParams(
                edits: edits,
                filePath: nil,
                expectedVersion: nil,
                reloadUserConfig: true
            ),
            responseType: AppServerConfigWriteResponse.self
        )
    }

}



package func forceRestart(
    _ discovery: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord? = nil,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2)
) async throws {
    try await forceRestart(
        discovery,
        runtimeState: runtimeState,
        terminateGracePeriod: terminateGracePeriod,
        killGracePeriod: killGracePeriod,
        clock: ContinuousClock()
    )
}

package func forceRestart<C: Clock>(
    _ discovery: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord? = nil,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2),
    clock: C
) async throws where C.Duration == Duration {
    do {
        try await forceStopDiscoveredServerProcess(
            discovery,
            terminateGracePeriod: terminateGracePeriod,
            killGracePeriod: killGracePeriod,
            runtimeState: runtimeState,
            clock: clock
        )
    } catch let error as ForcedRestartError {
        throw ReviewError.io(error.message)
    }
}

private func discoveryMatchesListenAddress(
    _ discovery: LiveEndpointRecord,
    host: String,
    port: Int
) -> Bool {
    guard discovery.port == port else {
        return false
    }
    return configuredHostCandidates(host).contains(normalizeLoopbackHost(discovery.host))
}

private func isAddressInUse(_ error: Error) -> Bool {
    String(describing: error).localizedCaseInsensitiveContains("address already in use")
}

private func normalizeLoopbackHost(_ host: String) -> String {
    if host == "localhost" || host == "::1" || host.hasPrefix("127.") {
        return "localhost"
    }
    return host
}

private func configuredHostCandidates(_ host: String) -> Set<String> {
    let configuredHost = normalizeLoopbackHost(
        normalizedDiscoveryHost(configuredHost: host, boundHost: host)
    )
    var candidates: Set<String> = [configuredHost]
    for candidate in resolvedHostCandidates(host) {
        candidates.insert(normalizeLoopbackHost(candidate))
    }
    for candidate in resolvedHostCandidates(configuredHost) {
        candidates.insert(normalizeLoopbackHost(candidate))
    }
    return candidates
}

private func resolvedHostCandidates(_ host: String) -> Set<String> {
    var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var results: UnsafeMutablePointer<addrinfo>?
    let status = host.withCString { rawHost in
        getaddrinfo(rawHost, nil, &hints, &results)
    }
    guard status == 0, let results else {
        return []
    }
    defer { freeaddrinfo(results) }

    var candidates: Set<String> = []
    var cursor: UnsafeMutablePointer<addrinfo>? = results
    while let entry = cursor {
        if let address = entry.pointee.ai_addr {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                address,
                entry.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                let length = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
                let numericHost = String(
                    decoding: hostBuffer[..<length].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                candidates.insert(numericHost)
            }
        }
        cursor = entry.pointee.ai_next
    }
    return candidates
}

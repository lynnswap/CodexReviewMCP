import Foundation
import ReviewAppServerIntegration

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

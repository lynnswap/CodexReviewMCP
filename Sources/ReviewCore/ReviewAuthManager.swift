import CodexReviewModel
import Foundation

package enum ReviewAuthError: LocalizedError, Sendable, Equatable {
    case authenticationRequired(String)
    case loginInProgress
    case loginFailed(String)
    case cancelled
    case logoutFailed(String)

    package var errorDescription: String? {
        switch self {
        case .authenticationRequired(let message),
             .loginFailed(let message),
             .logoutFailed(let message):
            message
        case .loginInProgress:
            "Authentication is already in progress."
        case .cancelled:
            "Authentication cancelled."
        }
    }
}

package let reviewAuthPersistenceFailureMessage =
    "Authentication completed in browser, but credentials were not persisted to ReviewMCP's dedicated home."

private enum DurableAuthCheckResult: Sendable {
    case signedIn(CodexReviewAuthModel.State)
    case signedOut
    case unavailable
}

package protocol ReviewAuthSession: Sendable {
    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse
    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse
    func cancelLogin(loginID: String) async throws
    func logout() async throws
    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification>
    func close() async
}

package actor ReviewAuthManager {
    package struct Configuration: Sendable {
        package var codexCommand: String
        package var environment: [String: String]
        package var startupTimeout: Duration
        package var durableAuthMaxAttempts: Int?
        package var durableAuthRetryDelay: Duration
        package var sleep: @Sendable (Duration) async throws -> Void

        package init(
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            startupTimeout: Duration = .seconds(30),
            durableAuthMaxAttempts: Int? = nil,
            durableAuthRetryDelay: Duration = .milliseconds(250),
            sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            }
        ) {
            self.codexCommand = codexCommand
            self.environment = environment
            self.startupTimeout = startupTimeout
            self.durableAuthMaxAttempts = durableAuthMaxAttempts
            self.durableAuthRetryDelay = durableAuthRetryDelay
            self.sleep = sleep
        }
    }

    private let configuration: Configuration
    private let sessionFactory: (@Sendable () async throws -> any ReviewAuthSession)?
    private var activeSession: (any ReviewAuthSession)?
    private var activeLoginID: String?
    private var activeAttemptID: UUID?
    private let accountReadTimeout: Duration = .seconds(2)
    private let postLoginAccountReadTimeout: Duration = .seconds(2)
    private let refreshedStateDurableVerificationTimeout: Duration = .seconds(2)

    package init(
        configuration: Configuration = .init(),
        sessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil
    ) {
        self.configuration = configuration
        self.sessionFactory = sessionFactory
    }

    package func loadState() async throws -> CodexReviewAuthModel.State {
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)
        let state = try await withTimeout(accountReadTimeout) {
            try await self.withSession { session in
                let account = try await session.readAccount(refreshToken: false)
                return Self.authState(from: account)
            }
        }
        return state
    }

    package func beginAuthentication(
        onUpdate: @escaping @Sendable (CodexReviewAuthModel.State) async -> Void
    ) async throws {
        guard activeAttemptID == nil else {
            throw ReviewAuthError.loginInProgress
        }
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)

        let attemptID = UUID()
        activeAttemptID = attemptID
        activeLoginID = nil
        let loginParams = AppServerLoginAccountParams.chatGPT
        await onUpdate(Self.initialProgressState())

        do {
            let session = try await makeSession()
            try await ensureAttemptIsCurrent(attemptID, closing: session)
            activeSession = session
            let response = try await session.startLogin(loginParams)
            try await ensureAttemptIsCurrent(attemptID, closing: session)
            if let loginID = response.loginID {
                activeLoginID = loginID
            }
            await onUpdate(Self.progressState(for: response))

            let finalState: CodexReviewAuthModel.State
            switch response {
            case .chatGPT(let loginID, _):
                finalState = try await waitForAuthenticationCompletion(
                    session: session,
                    attemptID: attemptID,
                    loginID: loginID,
                    onUpdate: onUpdate
                )
            }
            if finalState == .signedOut {
                throw ReviewAuthError.loginFailed("Authentication failed. Sign in again.")
            }

            guard await closeAttemptIfCurrent(attemptID) else {
                throw ReviewAuthError.cancelled
            }
            await onUpdate(finalState)
        } catch let error as ReviewAuthError {
            let closedCurrentAttempt = await closeAttemptIfCurrent(attemptID)
            if error != .cancelled, closedCurrentAttempt {
                await onUpdate(.failed(error.errorDescription ?? "Authentication failed."))
            }
            throw error
        } catch {
            let closedCurrentAttempt = await closeAttemptIfCurrent(attemptID)
            let wrappedError = ReviewAuthError.loginFailed(error.localizedDescription)
            if closedCurrentAttempt {
                await onUpdate(.failed(wrappedError.errorDescription ?? "Authentication failed."))
            }
            throw wrappedError
        }
    }

    package func cancelAuthentication() async {
        let session = activeSession
        let loginID = activeLoginID
        activeSession = nil
        activeLoginID = nil
        activeAttemptID = nil
        if let session, let loginID {
            do {
                try await session.cancelLogin(loginID: loginID)
            } catch {
            }
            await session.close()
        } else if let session {
            await session.close()
        }
    }

    package func logout() async throws -> CodexReviewAuthModel.State {
        guard activeAttemptID == nil else {
            throw ReviewAuthError.loginInProgress
        }
        return try await withSession { session in
            do {
                try await session.logout()
                return .signedOut
            } catch {
                throw ReviewAuthError.logoutFailed(
                    error.localizedDescription.nilIfEmpty ?? "Failed to sign out."
                )
            }
        }
    }

    private func makeSession() async throws -> any ReviewAuthSession {
        if let sessionFactory {
            return try await sessionFactory()
        }
        throw ReviewAuthError.loginFailed("Authentication service is unavailable.")
    }

    private func withSession<T>(
        _ operation: (any ReviewAuthSession) async throws -> T
    ) async throws -> T {
        let session = try await makeSession()
        defer {
            Task {
                await session.close()
            }
        }
        return try await operation(session)
    }

    private func waitForAuthenticationCompletion(
        session: any ReviewAuthSession,
        attemptID: UUID,
        loginID: String,
        onUpdate: @escaping @Sendable (CodexReviewAuthModel.State) async -> Void
    ) async throws -> CodexReviewAuthModel.State {
        let subscription = await session.notificationStream()
        defer {
            Task {
                await subscription.cancel()
            }
        }

        var sawAccountUpdate = false
        do {
            for try await notification in subscription.stream {
                guard isAttemptCurrent(attemptID, loginID: loginID) else {
                    throw ReviewAuthError.cancelled
                }
                switch notification {
                case .accountUpdated:
                    sawAccountUpdate = true
                    await onUpdate(
                        .signingIn(
                            .init(
                                title: "Sign in with ChatGPT",
                                detail: "Finalizing sign-in."
                            )
                        )
                    )
                case .accountLoginCompleted(let completed):
                    if let completedLoginID = completed.loginID?.nilIfEmpty,
                       completedLoginID != loginID
                    {
                        continue
                    }
                    guard completed.success else {
                        throw ReviewAuthError.loginFailed(
                            completed.error?.nilIfEmpty ?? "Authentication failed. Sign in again."
                        )
                    }
                    guard isAttemptCurrent(attemptID, loginID: loginID) else {
                        throw ReviewAuthError.cancelled
                    }
                    return try await signedInStateAfterAuthentication(session: session)
                default:
                    continue
                }
            }
        } catch is CancellationError {
            throw ReviewAuthError.cancelled
        } catch let error as ReviewAuthError {
            throw error
        } catch {
            if sawAccountUpdate {
                guard isAttemptCurrent(attemptID, loginID: loginID) else {
                    throw ReviewAuthError.cancelled
                }
                return try await signedInStateAfterAuthentication(session: session)
            }
            throw ReviewAuthError.loginFailed(error.localizedDescription)
        }

        if sawAccountUpdate {
            guard isAttemptCurrent(attemptID, loginID: loginID) else {
                throw ReviewAuthError.cancelled
            }
            return try await signedInStateAfterAuthentication(session: session)
        }
        throw ReviewAuthError.cancelled
    }

    private func ensureAttemptIsCurrent(
        _ attemptID: UUID,
        closing session: any ReviewAuthSession
    ) async throws {
        guard activeAttemptID == attemptID else {
            await session.close()
            throw ReviewAuthError.cancelled
        }
    }

    private func closeAttemptIfCurrent(_ attemptID: UUID) async -> Bool {
        guard activeAttemptID == attemptID else {
            return false
        }
        let session = activeSession
        activeSession = nil
        activeLoginID = nil
        activeAttemptID = nil
        if let session {
            await session.close()
        }
        return true
    }

    private func isAttemptCurrent(
        _ attemptID: UUID,
        loginID: String? = nil
    ) -> Bool {
        guard activeAttemptID == attemptID else {
            return false
        }
        if let loginID,
           let activeLoginID,
           activeLoginID != loginID
        {
            return false
        }
        return true
    }

    private func signedInStateAfterAuthentication(
        session: any ReviewAuthSession
    ) async throws -> CodexReviewAuthModel.State {
        let refreshedState: CodexReviewAuthModel.State
        do {
            let account = try await withTimeout(postLoginAccountReadTimeout) {
                try await session.readAccount(refreshToken: true)
            }
            refreshedState = Self.authState(from: account)
        } catch {
            let durableResult = try await durableAuthCheckResult(timeout: refreshedStateDurableVerificationTimeout)
            try ensureAuthenticationAttemptActive()
            switch durableResult {
            case .signedIn(let durableState):
                return durableState
            case .signedOut, .unavailable:
                throw ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)
            }
        }

        let durableResult = try await durableAuthCheckResult(timeout: refreshedStateDurableVerificationTimeout)
        try ensureAuthenticationAttemptActive()
        switch durableResult {
        case .signedIn(let durableState):
            return Self.confirmedSignedInState(
                refreshedState: refreshedState,
                durableState: durableState
            )
        case .signedOut:
            throw ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)
        case .unavailable:
            guard refreshedState != .signedOut else {
                throw ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)
            }
            return refreshedState
        }
    }

    private func ensureAuthenticationAttemptActive() throws {
        guard activeAttemptID != nil else {
            throw ReviewAuthError.cancelled
        }
    }

    private func durableAuthCheckResult(
        timeout: Duration? = nil
    ) async throws -> DurableAuthCheckResult {
        var sawSignedOut = false
        var sawUnavailable = false
        let maxAttempts = max(1, configuration.durableAuthMaxAttempts ?? .max)
        let deadline = ContinuousClock.now.advanced(by: timeout ?? configuration.startupTimeout)
        var attempt = 0

        while attempt < maxAttempts {
            guard activeAttemptID != nil else {
                throw ReviewAuthError.cancelled
            }
            attempt += 1
            do {
                let state = try await withTimeout(accountReadTimeout) {
                    try await self.withSession { session in
                        let account = try await session.readAccount(refreshToken: false)
                        return Self.authState(from: account)
                    }
                }
                if state == .signedOut {
                    sawSignedOut = true
                } else {
                    return .signedIn(state)
                }
            } catch is CancellationError {
                throw ReviewAuthError.cancelled
            } catch {
                sawUnavailable = true
            }

            if let configuredAttempts = configuration.durableAuthMaxAttempts,
               attempt >= max(1, configuredAttempts)
            {
                break
            }
            if ContinuousClock.now >= deadline {
                break
            }

            do {
                try await configuration.sleep(configuration.durableAuthRetryDelay)
            } catch is CancellationError {
                throw ReviewAuthError.cancelled
            } catch {
                sawUnavailable = true
                break
            }
        }

        if sawSignedOut {
            return .signedOut
        }
        if sawUnavailable {
            return .unavailable
        }
        return .signedOut
    }

    private static func confirmedSignedInState(
        refreshedState: CodexReviewAuthModel.State,
        durableState: CodexReviewAuthModel.State
    ) -> CodexReviewAuthModel.State {
        switch (refreshedState, durableState) {
        case (.signedIn(let refreshedAccountID), .signedIn(let durableAccountID))
            where refreshedAccountID == "ChatGPT" && durableAccountID != "ChatGPT":
            return .signedIn(accountID: durableAccountID)
        case (.signedIn(let refreshedAccountID), .signedIn)
            where refreshedAccountID != "ChatGPT":
            return .signedIn(accountID: refreshedAccountID)
        case (.signedOut, .signedIn):
            return durableState
        case (.signedIn, .signedIn):
            return refreshedState
        default:
            return durableState
        }
    }

    private static func initialProgressState() -> CodexReviewAuthModel.State {
        .signingIn(
            .init(
                title: "Sign in with ChatGPT",
                detail: "Preparing browser sign-in."
            )
        )
    }

    private static func progressState(
        for response: AppServerLoginAccountResponse
    ) -> CodexReviewAuthModel.State {
        switch response {
        case .chatGPT(_, let authURL):
            return .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser to continue sign-in.",
                    browserURL: authURL
                )
            )
        }
    }

    private static func authState(from response: AppServerAccountReadResponse) -> CodexReviewAuthModel.State {
        switch response.account {
        case .chatGPT(let email, _):
            return .signedIn(accountID: email.nilIfEmpty ?? "ChatGPT")
        case .unsupported:
            return .signedOut
        case nil:
            return .signedOut
        }
    }

}

package actor SharedAppServerReviewAuthSession: ReviewAuthSession {
    private let transport: any AppServerSessionTransport
    private var isClosed = false

    package init(transport: any AppServerSessionTransport) {
        self.transport = transport
    }

    package func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        let response: AppServerAccountReadResponse = try await transport.request(
            method: "account/read",
            params: AppServerAccountReadParams(refreshToken: refreshToken),
            responseType: AppServerAccountReadResponse.self
        )
        return response
    }

    package func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        let response: AppServerLoginAccountResponse = try await transport.request(
            method: "account/login/start",
            params: params,
            responseType: AppServerLoginAccountResponse.self
        )
        return response
    }

    package func cancelLogin(loginID: String) async throws {
        let response: AppServerCancelLoginAccountResponse = try await transport.request(
            method: "account/login/cancel",
            params: AppServerCancelLoginAccountParams(loginID: loginID),
            responseType: AppServerCancelLoginAccountResponse.self
        )
        _ = response
    }

    package func logout() async throws {
        let _: AppServerLogoutAccountResponse = try await transport.request(
            method: "account/logout",
            params: AppServerNullParams(),
            responseType: AppServerLogoutAccountResponse.self
        )
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        return await transport.notificationStream()
    }

    package func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        await transport.close()
    }
}

package actor CLIReviewAuthSession: ReviewAuthSession {
    private final class ActiveLoginProcess: @unchecked Sendable {
        let loginID: String
        let mode: AppServerLoginAccountParams
        let process: Process
        let stdinPipe: Pipe
        var stdoutTask: Task<Void, Never>?
        var stderrTask: Task<Void, Never>?
        var waitTask: Task<Void, Never>?
        var startResponseDelivered = false
        var browserURL: String?
        var outputLines: [String] = []

        init(
            loginID: String,
            mode: AppServerLoginAccountParams,
            process: Process,
            stdinPipe: Pipe
        ) {
            self.loginID = loginID
            self.mode = mode
            self.process = process
            self.stdinPipe = stdinPipe
        }
    }

    private let configuration: ReviewAuthManager.Configuration
    private var activeLogin: ActiveLoginProcess?
    private var pendingStartContinuation: CheckedContinuation<AppServerLoginAccountResponse, Error>?
    private var bufferedStartResult: Result<AppServerLoginAccountResponse, Error>?
    private var notificationSubscribers: [UUID: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation] = [:]
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var isClosed = false

    package init(configuration: ReviewAuthManager.Configuration) {
        self.configuration = configuration
    }

    package func readAccount(refreshToken _: Bool) async throws -> AppServerAccountReadResponse {
        let result = try await runCodexCommand(arguments: ["login", "status"])
        let combinedOutput = sanitizeCLIAuthOutput(result.stderr + "\n" + result.stdout)

        if result.exitCode == 0, combinedOutput.localizedCaseInsensitiveContains("Logged in") {
            let storedAccount = loadStoredCLIAuthAccount(environment: configuration.environment)
            return .init(
                account: .chatGPT(
                    email: storedAccount?.email?.nilIfEmpty ?? "ChatGPT",
                    planType: storedAccount?.planType?.nilIfEmpty ?? "unknown"
                ),
                requiresOpenAIAuth: false
            )
        }
        if combinedOutput.localizedCaseInsensitiveContains("Not logged in") {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        throw ReviewAuthError.authenticationRequired(combinedOutput.nilIfEmpty ?? "Unable to determine authentication state.")
    }

    package func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        guard activeLogin == nil else {
            throw ReviewAuthError.loginInProgress
        }

        let currentDirectory = FileManager.default.currentDirectoryPath
        guard let executable = resolveCodexCommand(
            requestedCommand: configuration.codexCommand,
            environment: configuration.environment,
            currentDirectory: currentDirectory
        ) else {
            throw ReviewAuthError.loginFailed("Unable to locate \(configuration.codexCommand) executable.")
        }

        let arguments: [String]
        switch params {
        case .chatGPT:
            arguments = reviewMCPCodexCommandArguments(["login"])
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = makeCLIReviewAuthEnvironment(from: configuration.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let loginID = UUID().uuidString
        try process.run()
        try? stdinPipe.fileHandleForWriting.close()

        let activeLogin = ActiveLoginProcess(
            loginID: loginID,
            mode: params,
            process: process,
            stdinPipe: stdinPipe
        )
        self.activeLogin = activeLogin
        activeLogin.stdoutTask = makeCLIAuthOutputTask(
            handle: stdoutPipe.fileHandleForReading,
            source: "stdout",
            loginID: loginID
        )
        activeLogin.stderrTask = makeCLIAuthOutputTask(
            handle: stderrPipe.fileHandleForReading,
            source: "stderr",
            loginID: loginID
        )
        activeLogin.waitTask = Task.detached { [weak self, weak process] in
            guard let process else {
                return
            }
            process.waitUntilExit()
            await self?.handleLoginProcessExit(
                loginID: loginID,
                exitCode: process.terminationStatus
            )
        }

        if let bufferedStartResult {
            self.bufferedStartResult = nil
            return try bufferedStartResult.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingStartContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.cancelActiveLoginProcess()
            }
        }
    }

    package func cancelLogin(loginID: String) async throws {
        guard activeLogin?.loginID == loginID else {
            return
        }
        await cancelActiveLoginProcess()
    }

    package func logout() async throws {
        let result = try await runCodexCommand(arguments: ["logout"])
        let combinedOutput = sanitizeCLIAuthOutput(result.stderr + "\n" + result.stdout)
        guard result.exitCode == 0 else {
            throw ReviewAuthError.logoutFailed(combinedOutput.nilIfEmpty ?? "Failed to sign out.")
        }
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation!
        let stream = AsyncThrowingStream<AppServerServerNotification, Error>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        let subscriberID = UUID()
        notificationSubscribers[subscriberID] = continuation
        let bufferedNotifications = self.bufferedNotifications
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
        continuation.onTermination = { _ in
            Task {
                await self.removeNotificationSubscriber(id: subscriberID)
            }
        }
        return .init(
            stream: stream,
            cancel: { [self] in
                await self.cancelNotificationSubscriber(id: subscriberID)
            }
        )
    }

    package func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        await cancelActiveLoginProcess()
        finishNotificationSubscribers()
    }

    private func runCodexCommand(arguments: [String]) async throws -> CLIAuthCommandResult {
        let currentDirectory = FileManager.default.currentDirectoryPath
        guard let executable = resolveCodexCommand(
            requestedCommand: configuration.codexCommand,
            environment: configuration.environment,
            currentDirectory: currentDirectory
        ) else {
            throw ReviewAuthError.loginFailed("Unable to locate \(configuration.codexCommand) executable.")
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = reviewMCPCodexCommandArguments(arguments)
        process.environment = makeCLIReviewAuthEnvironment(from: configuration.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        process.standardInput = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        if let stdinPipe = process.standardInput as? Pipe {
            try? stdinPipe.fileHandleForWriting.close()
        }

        let stdoutTask = Task.detached {
            let data = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let stderrTask = Task.detached {
            let data = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
        }

        return try await .init(
            exitCode: exitCode,
            stdout: stdoutTask.value,
            stderr: stderrTask.value
        )
    }

    private func makeCLIAuthOutputTask(
        handle: FileHandle,
        source: String,
        loginID: String
    ) -> Task<Void, Never> {
        Task.detached { [weak self] in
            var trailingFragment = ""
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    break
                }
                let chunk = String(decoding: data, as: UTF8.self)
                let split = splitCLIAuthOutputChunk(
                    existingFragment: trailingFragment,
                    chunk: chunk
                )
                trailingFragment = split.trailingFragment
                for line in split.completeLines {
                    await self?.handleLoginOutputLine(line, source: source, loginID: loginID)
                }
            }
            if trailingFragment.isEmpty == false {
                await self?.handleLoginOutputLine(trailingFragment, source: source, loginID: loginID)
            }
        }
    }

    private func handleLoginOutputLine(
        _ line: String,
        source: String,
        loginID: String
    ) {
        guard let activeLogin, activeLogin.loginID == loginID else {
            return
        }
        let cleaned = sanitizeCLIAuthOutput(line)
        guard cleaned.isEmpty == false else {
            return
        }
        activeLogin.outputLines.append(cleaned)
        if activeLogin.outputLines.count > 50 {
            activeLogin.outputLines.removeFirst(activeLogin.outputLines.count - 50)
        }

        switch activeLogin.mode {
        case .chatGPT:
            if activeLogin.browserURL == nil,
               let url = extractReviewAuthHTTPSURL(from: cleaned)
            {
                activeLogin.browserURL = url
            }
        }

        maybeResolveStartResponse(for: activeLogin)
    }

    private func maybeResolveStartResponse(for activeLogin: ActiveLoginProcess) {
        guard activeLogin.startResponseDelivered == false else {
            return
        }

        let response: AppServerLoginAccountResponse?
        switch activeLogin.mode {
        case .chatGPT:
            if let browserURL = activeLogin.browserURL {
                response = .chatGPT(
                    loginID: activeLogin.loginID,
                    authURL: browserURL
                )
            } else {
                response = nil
            }
        }

        guard let response else {
            return
        }
        activeLogin.startResponseDelivered = true
        resolveStartResult(.success(response))
    }

    private func handleLoginProcessExit(
        loginID: String,
        exitCode: Int32
    ) async {
        guard let activeLogin, activeLogin.loginID == loginID else {
            return
        }

        if activeLogin.startResponseDelivered == false {
            let output = activeLogin.outputLines.joined(separator: "\n")
            let message = output.nilIfEmpty ?? "Authentication did not produce a browser URL."
            resolveStartResult(.failure(ReviewAuthError.loginFailed(message)))
        }

        let success = exitCode == 0
        if success {
            broadcastNotification(.accountUpdated(.init(authMode: .chatGPT, planType: nil)))
        }
        broadcastNotification(
            .accountLoginCompleted(
                .init(
                    error: success ? nil : activeLogin.outputLines.joined(separator: "\n").nilIfEmpty,
                    loginID: loginID,
                    success: success
                )
            )
        )

        self.activeLogin = nil
        _ = await activeLogin.stdoutTask?.result
        _ = await activeLogin.stderrTask?.result
    }

    private func cancelActiveLoginProcess() async {
        guard let activeLogin else {
            return
        }
        if activeLogin.process.isRunning {
            activeLogin.process.terminate()
            try? await Task.sleep(for: .milliseconds(500))
            if activeLogin.process.isRunning {
                kill(activeLogin.process.processIdentifier, SIGKILL)
            }
        }
        try? activeLogin.stdinPipe.fileHandleForWriting.close()
        _ = await activeLogin.waitTask?.result
        _ = await activeLogin.stdoutTask?.result
        _ = await activeLogin.stderrTask?.result
        self.activeLogin = nil
    }

    private func resolveStartResult(_ result: Result<AppServerLoginAccountResponse, Error>) {
        if let continuation = pendingStartContinuation {
            pendingStartContinuation = nil
            continuation.resume(with: result)
        } else {
            bufferedStartResult = result
        }
    }

    private func broadcastNotification(_ notification: AppServerServerNotification) {
        bufferedNotifications.append(notification)
        if bufferedNotifications.count > 20 {
            bufferedNotifications.removeFirst(bufferedNotifications.count - 20)
        }
        for continuation in notificationSubscribers.values {
            continuation.yield(notification)
        }
    }

    private func finishNotificationSubscribers() {
        let continuations = notificationSubscribers.values
        notificationSubscribers.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeNotificationSubscriber(id: UUID) {
        notificationSubscribers[id] = nil
    }

    private func cancelNotificationSubscriber(id: UUID) {
        guard let continuation = notificationSubscribers.removeValue(forKey: id) else {
            return
        }
        continuation.finish()
    }
}

private struct CLIAuthCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct StoredCLIAuthAccount: Equatable, Sendable {
    let email: String?
    let planType: String?
}

private extension AppServerAccountReadResponse {
    func authState() -> CodexReviewAuthModel.State {
        switch account {
        case .chatGPT(let email, _):
            return .signedIn(accountID: email.nilIfEmpty)
        case .unsupported:
            return .signedOut
        case nil:
            return .signedOut
        }
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ReviewAuthError.loginFailed("Authentication request timed out.")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw ReviewAuthError.loginFailed("Authentication request timed out.")
        }
        return result
    }
}

private func makeCLIReviewAuthEnvironment(from environment: [String: String]) -> [String: String] {
    var environment = environment
    environment["CODEX_HOME"] = ReviewHomePaths.codexHomeURL(environment: environment).path
    environment.removeValue(forKey: "XPC_SERVICE_NAME")
    environment.removeValue(forKey: "XPC_FLAGS")
    environment.removeValue(forKey: "__CFBundleIdentifier")
    environment.removeValue(forKey: "CODEX_THREAD_ID")
    environment.removeValue(forKey: "CODEX_SHELL")
    environment.removeValue(forKey: "OS_ACTIVITY_DT_MODE")
    return environment
}

package func sanitizeCLIAuthOutput(_ text: String) -> String {
    let ansiPattern = "\u{001B}\\[[0-9;]*[A-Za-z]"
    let stripped = text.replacingOccurrences(
        of: ansiPattern,
        with: "",
        options: .regularExpression
    )
    return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
}

package func extractReviewAuthHTTPSURL(from text: String) -> String? {
    guard let range = text.range(
        of: #"https://[^\s]+"#,
        options: .regularExpression
    ) else {
        return nil
    }
    return String(text[range])
}

package func splitCLIAuthOutputChunk(
    existingFragment: String,
    chunk: String
) -> (completeLines: [String], trailingFragment: String) {
    let combined = existingFragment + chunk
    let segments = combined.split(
        omittingEmptySubsequences: false,
        whereSeparator: \.isNewline
    ).map(String.init)

    if combined.last?.isNewline == true {
        return (segments, "")
    }

    return (Array(segments.dropLast()), segments.last ?? combined)
}

private func loadStoredCLIAuthAccount(
    environment: [String: String]
) -> StoredCLIAuthAccount? {
    let authURL = ReviewHomePaths.reviewAuthURL(environment: environment)
    guard let data = try? Data(contentsOf: authURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let authMode = object["auth_mode"] as? String,
          authMode == "chatgpt",
          let tokens = object["tokens"] as? [String: Any]
    else {
        return nil
    }

    if let idToken = tokens["id_token"] as? String,
       let claims = decodeReviewAuthJWTClaims(idToken)
    {
        return .init(
            email: reviewAuthClaimString(from: claims, keyPath: ["email"]),
            planType: reviewAuthClaimString(
                from: claims,
                keyPath: ["https://api.openai.com/auth", "chatgpt_plan_type"]
            )
        )
    }

    return nil
}

private func decodeReviewAuthJWTClaims(_ token: String) -> [String: Any]? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 2 else {
        return nil
    }

    var payload = String(segments[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
        payload += String(repeating: "=", count: 4 - remainder)
    }

    guard let data = Data(base64Encoded: payload),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object
}

private func reviewAuthClaimString(
    from object: [String: Any],
    keyPath: [String]
) -> String? {
    var current: Any = object
    for key in keyPath {
        guard let dictionary = current as? [String: Any],
              let next = dictionary[key]
        else {
            return nil
        }
        current = next
    }
    return current as? String
}

package func reviewRequiresAuthentication(from message: String?) -> Bool {
    guard let normalized = message?.lowercased(), normalized.isEmpty == false else {
        return false
    }

    let patterns = [
        "401 unauthorized",
        "missing bearer",
        "missing token data",
        "no local auth available",
        "auth_manager_missing",
        "failed to load chatgpt credentials",
        "access token could not be refreshed",
        "token data is not available",
        "local auth is not a chatgpt login",
    ]

    if patterns.contains(where: normalized.contains) {
        return true
    }
    return false
}

package func reviewAuthDisplayMessage(
    from message: String?
) -> String? {
    guard reviewRequiresAuthentication(from: message) else {
        return message
    }
    return "Authentication required. Sign in to ReviewMCP and retry."
}

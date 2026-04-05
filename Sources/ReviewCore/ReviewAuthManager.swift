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

        package init(
            codexCommand: String = "codex",
            environment: [String: String] = ProcessInfo.processInfo.environment,
            startupTimeout: Duration = .seconds(30)
        ) {
            self.codexCommand = codexCommand
            self.environment = environment
            self.startupTimeout = startupTimeout
        }
    }

    private let configuration: Configuration
    private let sessionFactory: (@Sendable () async throws -> any ReviewAuthSession)?
    private var activeSession: (any ReviewAuthSession)?
    private var activeLoginID: String?
    private var activeAttemptID: UUID?
    private let accountReadTimeout: Duration = .seconds(2)
    private let postLoginAccountReadTimeout: Duration = .seconds(2)

    package init(
        configuration: Configuration = .init(),
        sessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil
    ) {
        self.configuration = configuration
        self.sessionFactory = sessionFactory
    }

    package func loadState() async throws -> CodexReviewAuthModel.State {
        reviewAuthDebug("loadState begin")
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)
        let state = try await withTimeout(accountReadTimeout) {
            try await self.withSession { session in
                let account = try await session.readAccount(refreshToken: false)
                return Self.authState(from: account)
            }
        }
        reviewAuthDebug("loadState completed state=\(String(describing: state))")
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
        reviewAuthDebug("beginAuthentication attempt=\(attemptID) initial progress")
        await onUpdate(Self.initialProgressState())

        do {
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) makeSession begin")
            let session = try await makeSession()
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) makeSession completed")
            try await ensureAttemptIsCurrent(attemptID, closing: session)
            activeSession = session
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) startLogin begin")
            let response = try await session.startLogin(loginParams)
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) startLogin completed response=\(response)")
            try await ensureAttemptIsCurrent(attemptID, closing: session)
            if let loginID = response.loginID {
                activeLoginID = loginID
                reviewAuthDebug("beginAuthentication attempt=\(attemptID) activeLoginID=\(loginID)")
            }
            await onUpdate(Self.progressState(for: response))

            let finalState: CodexReviewAuthModel.State
            switch response {
            case .chatGPT(let loginID, _):
                reviewAuthDebug("beginAuthentication attempt=\(attemptID) waiting for completion loginID=\(loginID)")
                finalState = try await waitForAuthenticationCompletion(
                    session: session,
                    attemptID: attemptID,
                    loginID: loginID,
                    onUpdate: onUpdate
                )
            case .chatGPTDeviceCode(let loginID, _, _):
                reviewAuthDebug("beginAuthentication attempt=\(attemptID) waiting for completion loginID=\(loginID)")
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
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) completed finalState=\(String(describing: finalState))")
            await onUpdate(finalState)
        } catch let error as ReviewAuthError {
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) failed reviewAuthError=\(error.errorDescription ?? String(describing: error))")
            let closedCurrentAttempt = await closeAttemptIfCurrent(attemptID)
            if error != .cancelled, closedCurrentAttempt {
                await onUpdate(.failed(error.errorDescription ?? "Authentication failed."))
            }
            throw error
        } catch {
            reviewAuthDebug("beginAuthentication attempt=\(attemptID) failed error=\(error.localizedDescription)")
            let closedCurrentAttempt = await closeAttemptIfCurrent(attemptID)
            let wrappedError = ReviewAuthError.loginFailed(error.localizedDescription)
            if closedCurrentAttempt {
                await onUpdate(.failed(wrappedError.errorDescription ?? "Authentication failed."))
            }
            throw wrappedError
        }
    }

    package func cancelAuthentication() async {
        reviewAuthDebug("cancelAuthentication begin activeLoginID=\(activeLoginID ?? "nil") activeAttemptID=\(activeAttemptID?.uuidString ?? "nil")")
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
        reviewAuthDebug("cancelAuthentication completed")
    }

    package func logout() async throws -> CodexReviewAuthModel.State {
        guard activeAttemptID == nil else {
            throw ReviewAuthError.loginInProgress
        }
        reviewAuthDebug("logout begin")
        return try await withSession { session in
            do {
                try await session.logout()
                reviewAuthDebug("logout completed")
                return .signedOut
            } catch {
                reviewAuthDebug("logout failed error=\(error.localizedDescription)")
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
                reviewAuthDebug("waitForAuthenticationCompletion attempt=\(attemptID) notification=\(notification)")
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
            reviewAuthDebug("ensureAttemptIsCurrent stale attempt=\(attemptID)")
            await session.close()
            throw ReviewAuthError.cancelled
        }
    }

    private func closeAttemptIfCurrent(_ attemptID: UUID) async -> Bool {
        guard activeAttemptID == attemptID else {
            return false
        }
        reviewAuthDebug("closeAttemptIfCurrent attempt=\(attemptID)")
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
        do {
            reviewAuthDebug("signedInStateAfterAuthentication account/read begin")
            let account = try await withTimeout(postLoginAccountReadTimeout) {
                try await session.readAccount(refreshToken: true)
            }
            reviewAuthDebug("signedInStateAfterAuthentication account/read completed account=\(String(describing: account.account))")
            return Self.authState(from: account)
        } catch {
            reviewAuthDebug("signedInStateAfterAuthentication fallback loadStoredAuthState error=\(error.localizedDescription)")
            return Self.loadStoredAuthState(environment: configuration.environment)
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
        case .chatGPTDeviceCode(_, let verificationURL, let userCode):
            return .signingIn(
                .init(
                    title: "Sign in with ChatGPT",
                    detail: "Open the browser and enter the code below.",
                    browserURL: verificationURL,
                    userCode: userCode
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

    private static func loadStoredAuthState(
        environment: [String: String]
    ) -> CodexReviewAuthModel.State {
        guard let account = loadStoredCLIAuthAccount(environment: environment) else {
            return .signedIn(accountID: "ChatGPT")
        }
        return .signedIn(accountID: account.email?.nilIfEmpty ?? "ChatGPT")
    }
}

package actor SharedAppServerReviewAuthSession: ReviewAuthSession {
    private let transport: any AppServerSessionTransport
    private var isClosed = false

    package init(transport: any AppServerSessionTransport) {
        self.transport = transport
    }

    package func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        reviewAuthDebug("SharedAppServerReviewAuthSession.readAccount begin refreshToken=\(refreshToken)")
        let response: AppServerAccountReadResponse = try await transport.request(
            method: "account/read",
            params: AppServerAccountReadParams(refreshToken: refreshToken),
            responseType: AppServerAccountReadResponse.self
        )
        reviewAuthDebug("SharedAppServerReviewAuthSession.readAccount completed account=\(String(describing: response.account)) requiresOpenAIAuth=\(response.requiresOpenAIAuth)")
        return response
    }

    package func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        reviewAuthDebug("SharedAppServerReviewAuthSession.startLogin begin params=\(params)")
        let response: AppServerLoginAccountResponse = try await transport.request(
            method: "account/login/start",
            params: params,
            responseType: AppServerLoginAccountResponse.self
        )
        reviewAuthDebug("SharedAppServerReviewAuthSession.startLogin completed response=\(response)")
        return response
    }

    package func cancelLogin(loginID: String) async throws {
        reviewAuthDebug("SharedAppServerReviewAuthSession.cancelLogin begin loginID=\(loginID)")
        let response: AppServerCancelLoginAccountResponse = try await transport.request(
            method: "account/login/cancel",
            params: AppServerCancelLoginAccountParams(loginID: loginID),
            responseType: AppServerCancelLoginAccountResponse.self
        )
        reviewAuthDebug(
            "SharedAppServerReviewAuthSession.cancelLogin completed loginID=\(loginID) status=\(response.status.rawValue)"
        )
    }

    package func logout() async throws {
        reviewAuthDebug("SharedAppServerReviewAuthSession.logout begin")
        let _: AppServerLogoutAccountResponse = try await transport.request(
            method: "account/logout",
            params: AppServerNullParams(),
            responseType: AppServerLogoutAccountResponse.self
        )
        reviewAuthDebug("SharedAppServerReviewAuthSession.logout completed")
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        reviewAuthDebug("SharedAppServerReviewAuthSession.notificationStream begin")
        return await transport.notificationStream()
    }

    package func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        reviewAuthDebug("SharedAppServerReviewAuthSession.close")
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
        var userCode: String?
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
        reviewAuthDebug("CLIReviewAuthSession.readAccount begin")
        let result = try await runCodexCommand(arguments: ["login", "status"])
        let combinedOutput = sanitizeCLIAuthOutput(result.stderr + "\n" + result.stdout)
        reviewAuthDebug(
            "CLIReviewAuthSession.readAccount completed exitCode=\(result.exitCode) output=\(combinedOutput)"
        )

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
        reviewAuthDebug("CLIReviewAuthSession.startLogin begin params=\(params)")
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
            arguments = ["login"]
        case .chatGPTDeviceCode:
            arguments = ["login", "--device-auth"]
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
        reviewAuthDebug(
            "CLIReviewAuthSession.startLogin launching executable=\(executable) arguments=\(arguments.joined(separator: " ")) loginID=\(loginID)"
        )
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
        reviewAuthDebug("CLIReviewAuthSession.cancelLogin begin loginID=\(loginID)")
        guard activeLogin?.loginID == loginID else {
            return
        }
        await cancelActiveLoginProcess()
        reviewAuthDebug("CLIReviewAuthSession.cancelLogin completed loginID=\(loginID)")
    }

    package func logout() async throws {
        reviewAuthDebug("CLIReviewAuthSession.logout begin")
        let result = try await runCodexCommand(arguments: ["logout"])
        let combinedOutput = sanitizeCLIAuthOutput(result.stderr + "\n" + result.stdout)
        reviewAuthDebug(
            "CLIReviewAuthSession.logout completed exitCode=\(result.exitCode) output=\(combinedOutput)"
        )
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
        reviewAuthDebug("CLIReviewAuthSession.close")
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
        process.arguments = arguments
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
        reviewAuthDebug("CLIReviewAuthSession.\(source) \(cleaned)")
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
        case .chatGPTDeviceCode:
            if activeLogin.browserURL == nil,
               let url = extractReviewAuthHTTPSURL(from: cleaned)
            {
                activeLogin.browserURL = url
            }
            if activeLogin.userCode == nil,
               let userCode = extractReviewAuthUserCode(from: cleaned)
            {
                activeLogin.userCode = userCode
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
        case .chatGPTDeviceCode:
            if let browserURL = activeLogin.browserURL,
               let userCode = activeLogin.userCode
            {
                response = .chatGPTDeviceCode(
                    loginID: activeLogin.loginID,
                    verificationURL: browserURL,
                    userCode: userCode
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
        reviewAuthDebug("CLIReviewAuthSession.cancelActiveLoginProcess loginID=\(activeLogin.loginID)")
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

private func reviewAuthDebug(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    fputs("[codex-review-mcp.auth] \(timestamp) \(message)\n", stderr)
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

package func extractReviewAuthUserCode(from text: String) -> String? {
    guard let range = text.range(
        of: #"\b[A-Z0-9]{4,5}-[A-Z0-9]{4,5}\b"#,
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

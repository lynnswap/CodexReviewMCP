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

    package init(
        configuration: Configuration = .init(),
        sessionFactory: (@Sendable () async throws -> any ReviewAuthSession)? = nil
    ) {
        self.configuration = configuration
        self.sessionFactory = sessionFactory
    }

    package func loadState() async throws -> CodexReviewAuthModel.State {
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)
        return try await withSession { session in
            let account = try await session.readAccount(refreshToken: false)
            return Self.authState(from: account)
        }
    }

    package func beginAuthentication(
        onUpdate: @escaping @Sendable (CodexReviewAuthModel.State) async -> Void
    ) async throws {
        guard activeSession == nil else {
            throw ReviewAuthError.loginInProgress
        }
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)

        let loginParams = AppServerLoginAccountParams.chatGPT
        let session = try await makeSession()
        activeSession = session
        activeLoginID = nil

        do {
            await onUpdate(Self.initialProgressState())
            let response = try await session.startLogin(loginParams)
            if let loginID = response.loginID {
                activeLoginID = loginID
            }
            await onUpdate(Self.progressState(for: response))

            let finalState: CodexReviewAuthModel.State
            switch response {
            case .chatGPT(let loginID, _):
                finalState = try await waitForAuthenticationCompletion(
                    session: session,
                    loginID: loginID,
                    onUpdate: onUpdate
                )
            }
            if finalState == .signedOut {
                throw ReviewAuthError.loginFailed("Authentication failed. Sign in again.")
            }

            await closeActiveSession()
            await onUpdate(finalState)
        } catch let error as ReviewAuthError {
            await closeActiveSession()
            if error != .cancelled {
                await onUpdate(.failed(error.errorDescription ?? "Authentication failed."))
            }
            throw error
        } catch {
            await closeActiveSession()
            let wrappedError = ReviewAuthError.loginFailed(error.localizedDescription)
            await onUpdate(.failed(wrappedError.errorDescription ?? "Authentication failed."))
            throw wrappedError
        }
    }

    package func cancelAuthentication() async {
        let loginID = activeLoginID
        if let activeSession, let loginID {
            do {
                try await activeSession.cancelLogin(loginID: loginID)
            } catch {
            }
        }
        await closeActiveSession()
    }

    package func logout() async throws -> CodexReviewAuthModel.State {
        guard activeSession == nil else {
            throw ReviewAuthError.loginInProgress
        }
        return try await withSession { session in
            do {
                try await session.logout()
                let account = try await session.readAccount(refreshToken: false)
                return account.authState()
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
        return try await makeLiveReviewAuthSession(configuration: configuration)
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

    private func closeActiveSession() async {
        let session = activeSession
        activeSession = nil
        activeLoginID = nil
        if let session {
            await session.close()
        }
    }

    private func waitForAuthenticationCompletion(
        session: any ReviewAuthSession,
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
                    let account = try await session.readAccount(refreshToken: true)
                    return Self.authState(from: account)
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
                let account = try await session.readAccount(refreshToken: true)
                return Self.authState(from: account)
            }
            throw ReviewAuthError.loginFailed(error.localizedDescription)
        }

        if sawAccountUpdate {
            let account = try await session.readAccount(refreshToken: true)
            return Self.authState(from: account)
        }
        throw ReviewAuthError.cancelled
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
                    detail: "Finish signing in via your browser.",
                    browserURL: authURL
                )
            )
        }
    }

    private static func authState(from response: AppServerAccountReadResponse) -> CodexReviewAuthModel.State {
        switch response.account {
        case .chatGPT(let email, _):
            return .signedIn(accountID: email.nilIfEmpty)
        case .unsupported:
            return .signedOut
        case nil:
            return .signedOut
        }
    }
}

package func makeLiveReviewAuthSession(
    configuration: ReviewAuthManager.Configuration
) async throws -> any ReviewAuthSession {
    try await ReviewAuthAppServerSession.connect(configuration: configuration)
}

package actor ReviewAuthAppServerSession: ReviewAuthSession {
    private let transport: any AppServerSessionTransport
    private let process: Process
    private let stderrTask: Task<Void, Never>
    private let tokenFileURL: URL
    private let diagnostics: ReviewAuthDiagnosticsBuffer
    private var isClosed = false

    private init(
        transport: any AppServerSessionTransport,
        process: Process,
        stderrTask: Task<Void, Never>,
        tokenFileURL: URL,
        diagnostics: ReviewAuthDiagnosticsBuffer
    ) {
        self.transport = transport
        self.process = process
        self.stderrTask = stderrTask
        self.tokenFileURL = tokenFileURL
        self.diagnostics = diagnostics
    }

    static func connect(
        configuration: ReviewAuthManager.Configuration
    ) async throws -> ReviewAuthAppServerSession {
        try ReviewHomePaths.ensureReviewHomeScaffold(environment: configuration.environment)

        let tokenFileURL = ReviewHomePaths.appServerWebSocketTokenFileURL(
            launchID: UUID(),
            environment: configuration.environment
        )
        let authToken = UUID().uuidString
        try Data(authToken.utf8).write(to: tokenFileURL, options: .atomic)

        let command = try resolvedCodexCommand(configuration: configuration)
        let websocketURL = try makeLoopbackWebSocketListenURL()
        let diagnostics = ReviewAuthDiagnosticsBuffer()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = [
            "app-server",
            "--listen", websocketURL.absoluteString,
            "--ws-auth", "capability-token",
            "--ws-token-file", tokenFileURL.path,
        ]
        process.environment = dedicatedEnvironment(configuration: configuration)
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: tokenFileURL)
            throw ReviewAuthError.loginFailed(
                "Failed to start authentication service: \(error.localizedDescription)"
            )
        }

        let stderrTask = Task.detached {
            var buffer = Data()
            do {
                for try await byte in stderrPipe.fileHandleForReading.bytes {
                    buffer.append(byte)
                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let lineData = Data(buffer.prefix(upTo: newlineIndex))
                        buffer.removeSubrange(...newlineIndex)
                        if let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           line.isEmpty == false
                        {
                            diagnostics.append(line)
                        }
                    }
                }
                if let line = String(data: buffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   line.isEmpty == false
                {
                    diagnostics.append(line)
                }
            } catch {
            }
        }

        do {
            try await waitUntilReady(
                process: process,
                websocketURL: websocketURL,
                diagnostics: diagnostics,
                timeout: configuration.startupTimeout
            )
            let transport = try await AppServerWebSocketSessionTransport.connect(
                websocketURL: websocketURL,
                authToken: authToken,
                clientName: codexReviewMCPName,
                clientTitle: "Codex Review MCP Login",
                clientVersion: codexReviewMCPVersion
            )
            return ReviewAuthAppServerSession(
                transport: transport,
                process: process,
                stderrTask: stderrTask,
                tokenFileURL: tokenFileURL,
                diagnostics: diagnostics
            )
        } catch {
            let session = ReviewAuthAppServerSession(
                transport: ClosedAuthTransport(),
                process: process,
                stderrTask: stderrTask,
                tokenFileURL: tokenFileURL,
                diagnostics: diagnostics
            )
            await session.close()
            throw error
        }
    }

    package func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        try await transport.request(
            method: "account/read",
            params: AppServerAccountReadParams(refreshToken: refreshToken),
            responseType: AppServerAccountReadResponse.self
        )
    }

    package func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        try await transport.request(
            method: "account/login/start",
            params: params,
            responseType: AppServerLoginAccountResponse.self
        )
    }

    package func cancelLogin(loginID: String) async throws {
        let _: AppServerEmptyResponse = try await transport.request(
            method: "account/login/cancel",
            params: AppServerCancelLoginAccountParams(loginID: loginID),
            responseType: AppServerEmptyResponse.self
        )
    }

    package func logout() async throws {
        let _: AppServerLogoutAccountResponse = try await transport.request(
            method: "account/logout",
            params: AppServerNullParams(),
            responseType: AppServerLogoutAccountResponse.self
        )
    }

    package func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        await transport.notificationStream()
    }

    package func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        await transport.close()
        process.terminate()
        if process.isRunning {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
            }
        }
        if process.isRunning {
            process.interrupt()
        }
        if process.isRunning {
            process.terminate()
        }
        if process.isRunning {
            process.waitUntilExit()
        }
        stderrTask.cancel()
        _ = await stderrTask.result
        try? FileManager.default.removeItem(at: tokenFileURL)
    }
}

private struct ClosedAuthTransport: AppServerSessionTransport {
    func initializeResponse() async -> AppServerInitializeResponse { .init() }

    func request<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params,
        responseType: Response.Type
    ) async throws -> Response {
        _ = method
        _ = params
        _ = responseType
        throw AuthTransportError.closed
    }

    func notify<Params: Encodable & Sendable>(method: String, params: Params) async throws {
        _ = method
        _ = params
        throw AuthTransportError.closed
    }

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        .init(stream: .init { $0.finish() }, cancel: {})
    }

    func isClosed() async -> Bool { true }

    func close() async {}
}

private enum AuthTransportError: LocalizedError {
    case closed

    var errorDescription: String? {
        "auth transport is closed."
    }
}

private final class ReviewAuthDiagnosticsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
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

private func dedicatedEnvironment(
    configuration: ReviewAuthManager.Configuration
) -> [String: String] {
    var environment = configuration.environment
    environment["CODEX_HOME"] = ReviewHomePaths.reviewHomeURL(environment: configuration.environment).path
    return environment
}

private func resolvedCodexCommand(
    configuration: ReviewAuthManager.Configuration
) throws -> String {
    guard let command = resolveCodexCommand(
        requestedCommand: configuration.codexCommand,
        environment: dedicatedEnvironment(configuration: configuration),
        currentDirectory: FileManager.default.currentDirectoryPath
    ) else {
        throw ReviewAuthError.loginFailed(
            "Unable to locate \(configuration.codexCommand) executable. Set --codex-command or ensure PATH contains \(configuration.codexCommand)."
        )
    }
    return command
}

private func waitUntilReady(
    process: Process,
    websocketURL: URL,
    diagnostics: ReviewAuthDiagnosticsBuffer,
    timeout: Duration
) async throws {
    let readyURL = try authReadyURL(from: websocketURL)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    while ContinuousClock.now < deadline {
        if process.isRunning == false {
            let suffix = diagnostics.snapshot().joined(separator: "\n").nilIfEmpty.map { ": \($0)" } ?? ""
            throw ReviewAuthError.loginFailed("Authentication service exited before becoming ready\(suffix)")
        }

        var request = URLRequest(url: readyURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1
        if let (_, response) = try? await session.data(for: request),
           let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200
        {
            return
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    throw ReviewAuthError.loginFailed("Timed out waiting for authentication service to become ready.")
}

private func authReadyURL(from websocketURL: URL) throws -> URL {
    guard var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
        throw ReviewAuthError.loginFailed("Failed to construct readyz URL.")
    }
    components.scheme = "http"
    components.path = "/readyz"
    guard let url = components.url else {
        throw ReviewAuthError.loginFailed("Failed to construct readyz URL.")
    }
    return url
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

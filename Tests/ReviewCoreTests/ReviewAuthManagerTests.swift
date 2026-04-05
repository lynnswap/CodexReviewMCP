import Foundation
import Testing
import CodexReviewModel
@testable import ReviewCore

@Suite(.serialized)
struct ReviewAuthManagerTests {
    @Test func authManagerLoadsUnauthenticatedStateFromAccountRead() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [.init(account: nil, requiresOpenAIAuth: true)]
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )

        #expect(try await manager.loadState() == .signedOut)
        #expect(await session.recordedRefreshRequests() == [false])
    }

    @Test func authManagerBrowserLoginPublishesAuthURLAndFinalAccountEmail() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [
                .init(account: .chatGPT(email: "review@example.com", planType: "plus"), requiresOpenAIAuth: false),
            ],
            loginResponse: .chatGPT(
                loginID: "login-browser",
                authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        let task = Task {
            try await manager.beginAuthentication { state in
                await recorder.append(state)
            }
        }

        try await waitUntil(timeout: .seconds(2)) {
            let params = await session.recordedLoginParams()
            return params == [.chatGPT] ? true : nil
        }
        await session.send(.accountUpdated(.init(authMode: .chatGPT, planType: "plus")))
        await session.send(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))

        try await task.value

        let updates = await recorder.values()
        #expect(
            updates.contains {
                guard case .signingIn(let progress) = $0 else {
                    return false
                }
                return progress.browserURL?.contains("/oauth/authorize") == true
                    && progress.userCode == nil
            }
        )
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
        #expect(await session.recordedRefreshRequests() == [true])
    }

    @Test func authManagerDeviceCodeLoginPublishesVerificationURLAndCode() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [],
            loginResponse: .chatGPTDeviceCode(
                loginID: "login-browser",
                verificationURL: "https://auth.openai.com/codex/device",
                userCode: "ABCD-1234"
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        let task = Task {
            try await manager.beginAuthentication { state in
                await recorder.append(state)
            }
        }

        try await waitUntil(timeout: .seconds(2)) {
            let params = await session.recordedLoginParams()
            return params == [.chatGPT] ? true : nil
        }
        await session.finishNotifications(with: CancellationError())
        await #expect(throws: ReviewAuthError.cancelled) {
            try await task.value
        }

        let updates = await recorder.values()
        #expect(updates.contains {
            guard case .signingIn(let progress) = $0 else {
                return false
            }
            return progress.browserURL?.contains("/codex/device") == true
                && progress.userCode == "ABCD-1234"
        })
    }

    @Test func authManagerPublishesInitialProgressBeforeSessionCreationCompletes() async throws {
        let session = FakeReviewAuthSession(readResponses: [])
        let factory = BlockingReviewAuthSessionFactory(session: session)
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: {
                try await factory.makeSession()
            }
        )
        let recorder = AuthUpdateRecorder()

        let task = Task {
            try await manager.beginAuthentication { state in
                await recorder.append(state)
            }
        }

        await factory.waitForRequest()
        try await waitUntil(timeout: .seconds(2)) {
            let updates = await recorder.values()
            return updates.contains {
                guard case .signingIn(let progress) = $0 else {
                    return false
                }
                return progress.browserURL == nil
                    && progress.detail == "Preparing browser sign-in."
            } ? true : nil
        }

        await factory.resume()
        try await waitUntil(timeout: .seconds(2)) {
            let params = await session.recordedLoginParams()
            return params == [.chatGPT] ? true : nil
        }

        await manager.cancelAuthentication()
        await session.finishNotifications(with: CancellationError())
        await #expect(throws: ReviewAuthError.cancelled) {
            try await task.value
        }
    }

    @Test func authManagerTreatsUnsupportedAccountAsSignedOut() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [.init(account: .unsupported, requiresOpenAIAuth: true)]
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )

        #expect(try await manager.loadState() == .signedOut)
    }

    @Test func authManagerCancelAuthenticationCancelsActiveLoginID() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [],
            loginResponse: .chatGPTDeviceCode(
                loginID: "login-browser",
                verificationURL: "https://auth.openai.com/codex/device",
                userCode: "ABCD-1234"
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )

        let task = Task {
            try await manager.beginAuthentication { _ in }
        }

        try await waitUntil(timeout: .seconds(2)) {
            let params = await session.recordedLoginParams()
            return params == [.chatGPT] ? true : nil
        }

        await manager.cancelAuthentication()
        await session.finishNotifications(with: CancellationError())

        await #expect(throws: ReviewAuthError.cancelled) {
            try await task.value
        }
        #expect(await session.cancelledLoginIDs() == ["login-browser"])
    }

    @Test func authManagerLogoutReturnsUnauthenticatedState() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [.init(account: nil, requiresOpenAIAuth: true)]
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )

        let state = try await manager.logout()

        #expect(state == .signedOut)
        #expect(await session.logoutCallCount() == 1)
    }

    @Test func fakeReviewAuthSessionDeviceCodeStartReturnsVerificationURLAndLoginID() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [],
            loginResponse: .chatGPTDeviceCode(
                loginID: "login-browser",
                verificationURL: "https://auth.openai.com/codex/device",
                userCode: "ABCD-1234"
            )
        )

        let response = try await session.startLogin(.chatGPTDeviceCode)

        guard case .chatGPTDeviceCode(let loginID, let verificationURL, let userCode) = response else {
            Issue.record("Expected chatgpt device code response, got \(response)")
            return
        }
        #expect(loginID.isEmpty == false)
        #expect(verificationURL.contains("/codex/device"))
        #expect(userCode == "ABCD-1234")
    }

    @Test func reviewAuthRequirementDetectsUnauthorizedFailures() {
        #expect(
            reviewRequiresAuthentication(
                from: "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
            )
        )
        #expect(
            reviewAuthDisplayMessage(
                from: "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
            ) == "Authentication required. Sign in to ReviewMCP and retry."
        )
    }

    @Test func cliAuthOutputHelpersExtractBrowserURLAndDeviceCode() {
        let browserLine = "\u{001B}[94mhttps://auth.openai.com/oauth/authorize?foo=bar\u{001B}[0m"
        let codeLine = "   \u{001B}[94m10Y1-AO4WU\u{001B}[0m"

        #expect(sanitizeCLIAuthOutput(browserLine) == "https://auth.openai.com/oauth/authorize?foo=bar")
        #expect(extractReviewAuthHTTPSURL(from: sanitizeCLIAuthOutput(browserLine)) == "https://auth.openai.com/oauth/authorize?foo=bar")
        #expect(extractReviewAuthUserCode(from: sanitizeCLIAuthOutput(codeLine)) == "10Y1-AO4WU")
    }
}

private actor AuthUpdateRecorder {
    private var updates: [CodexReviewAuthModel.State] = []

    func append(_ state: CodexReviewAuthModel.State) {
        updates.append(state)
    }

    func values() -> [CodexReviewAuthModel.State] {
        updates
    }
}

private actor BlockingReviewAuthSessionFactory {
    private let session: FakeReviewAuthSession
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumed = false

    init(session: FakeReviewAuthSession) {
        self.session = session
    }

    func makeSession() async throws -> any ReviewAuthSession {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if resumed == false {
            await withCheckedContinuation { continuation in
                resumeWaiters.append(continuation)
            }
        }
        return session
    }

    func waitForRequest() async {
        if requested {
            return
        }
        await withCheckedContinuation { continuation in
            if requested {
                continuation.resume()
            } else {
                requestWaiters.append(continuation)
            }
        }
    }

    func resume() {
        resumed = true
        let waiters = resumeWaiters
        resumeWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor FakeReviewAuthSession: ReviewAuthSession {
    private var readResponses: [AppServerAccountReadResponse]
    private let loginResponse: AppServerLoginAccountResponse
    private var refreshRequests: [Bool] = []
    private var loginParams: [AppServerLoginAccountParams] = []
    private var cancelledIDs: [String] = []
    private var logoutCalls = 0
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?

    init(
        readResponses: [AppServerAccountReadResponse],
        loginResponse: AppServerLoginAccountResponse = .chatGPTDeviceCode(
            loginID: "login-default",
            verificationURL: "https://auth.openai.com/codex/device",
            userCode: "WXYZ-9876"
        )
    ) {
        self.readResponses = readResponses
        self.loginResponse = loginResponse
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        refreshRequests.append(refreshToken)
        guard readResponses.isEmpty == false else {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        return readResponses.removeFirst()
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        loginParams.append(params)
        return loginResponse
    }

    func cancelLogin(loginID: String) async throws {
        cancelledIDs.append(loginID)
    }

    func logout() async throws {
        logoutCalls += 1
    }

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let stream = AsyncThrowingStream<AppServerServerNotification, Error> { continuation in
            Task {
                self.setContinuation(continuation)
            }
        }
        return .init(
            stream: stream,
            cancel: { [self] in
                await finishNotifications()
            }
        )
    }

    func close() async {
        finishNotifications()
    }

    func send(_ notification: AppServerServerNotification) {
        continuation?.yield(notification)
    }

    func finishNotifications(with error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    func recordedRefreshRequests() -> [Bool] {
        refreshRequests
    }

    func recordedLoginParams() -> [AppServerLoginAccountParams] {
        loginParams
    }

    func cancelledLoginIDs() -> [String] {
        cancelledIDs
    }

    func logoutCallCount() -> Int {
        logoutCalls
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
    }
}

private func waitUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async throws -> Bool?
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let matched = try await condition(), matched {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TestFailure("timed out waiting for condition")
}

private func makeTemporaryRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

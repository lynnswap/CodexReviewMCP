import Foundation
import Testing
import CodexReviewModel
import ReviewTestSupport
@testable import ReviewCore

@Suite(.serialized)
struct ReviewAuthManagerTests {
    @Test func authManagerLoadsUnauthenticatedStateFromAccountRead() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [.init(account: nil, requiresOpenAIAuth: true)]
        )
        let manager = ReviewAuthManager(
            configuration: .init(
                environment: ["HOME": makeTemporaryRoot().path],
                durableAuthMaxAttempts: 3,
                durableAuthRetryDelay: .zero
            ),
            sessionFactory: { session }
        )

        #expect(try await manager.loadState() == .signedOut)
        #expect(await session.recordedRefreshRequests() == [false])
    }

    @Test func authManagerBrowserLoginPublishesAuthURLAndFinalAccountEmail() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [
                .init(account: .chatGPT(email: "review@example.com", planType: "plus"), requiresOpenAIAuth: false),
                .init(account: .chatGPT(email: "review@example.com", planType: "plus"), requiresOpenAIAuth: false),
            ],
            loginResponse: .chatGPT(
                loginID: "login-browser",
                authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(
                environment: ["HOME": makeTemporaryRoot().path],
                durableAuthMaxAttempts: 3,
                durableAuthRetryDelay: .zero
            ),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        let task = Task {
            try await manager.beginAuthentication { state in
                await recorder.append(state)
            }
        }

        await session.waitForLoginStart()
        await session.send(.accountUpdated(.init(authMode: .chatGPT, planType: "plus")))
        await session.send(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))

        try await task.value

        let updates = await recorder.values()
        #expect(
            updates.contains {
                guard let progress = CodexReviewAuthStateAccessors.progress($0) else {
                    return false
                }
                return progress.browserURL?.contains("/oauth/authorize") == true
            }
        )
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
        #expect(await session.recordedRefreshRequests() == [true, false])
    }

    @Test func authManagerFallsBackToDurableSignedInStateAfterPostLoginReadFails() async throws {
        let session = PostLoginDurableCheckReviewAuthSession(
            durableResponse: .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            ),
            postLoginRefreshError: NSError(
                domain: "ReviewAuthManagerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "refresh failed"]
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(
                environment: ["HOME": makeTemporaryRoot().path],
                durableAuthMaxAttempts: 3,
                durableAuthRetryDelay: .zero
            ),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        try await manager.beginAuthentication { state in
            await recorder.append(state)
        }

        let updates = await recorder.values()
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
        #expect(await session.recordedRefreshRequests() == [true, false])
    }

    @Test func authManagerPrefersRefreshedIdentityWhenDurableCheckIsGeneric() async throws {
        let session = PostLoginDurableCheckReviewAuthSession(
            durableResponse: .init(
                account: .chatGPT(email: "ChatGPT", planType: "unknown"),
                requiresOpenAIAuth: false
            ),
            refreshedResponse: .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            ),
            postLoginRefreshError: nil
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        try await manager.beginAuthentication { state in
            await recorder.append(state)
        }

        let updates = await recorder.values()
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
        #expect(await session.recordedRefreshRequests() == [true, false])
    }

    @Test func authManagerPrefersDurableIdentityWhenRefreshIsGeneric() async throws {
        let session = PostLoginDurableCheckReviewAuthSession(
            durableResponse: .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            ),
            refreshedResponse: .init(
                account: .chatGPT(email: "ChatGPT", planType: "unknown"),
                requiresOpenAIAuth: false
            ),
            postLoginRefreshError: nil
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        try await manager.beginAuthentication { state in
            await recorder.append(state)
        }

        let updates = await recorder.values()
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
        #expect(await session.recordedRefreshRequests() == [true, false])
    }

    @Test func authManagerKeepsRefreshedIdentityWhenDurableProbeIsUnavailable() async throws {
        let session = PostLoginDurableCheckReviewAuthSession(
            durableResponse: .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            ),
            refreshedResponse: .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            ),
            postLoginRefreshError: nil,
            durableCheckError: NSError(
                domain: "ReviewAuthManagerTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "status unavailable"]
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        try await manager.beginAuthentication { state in
            await recorder.append(state)
        }

        let updates = await recorder.values()
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
    }

    @Test func authManagerRetriesDurableProbeWhenAuthAppearsAfterPropagationLag() async throws {
        let session = EventuallyPersistentLoginReviewAuthSession()
        let manager = ReviewAuthManager(
            configuration: .init(
                environment: ["HOME": makeTemporaryRoot().path],
                durableAuthMaxAttempts: 2,
                durableAuthRetryDelay: .zero
            ),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        try await manager.beginAuthentication { state in
            await recorder.append(state)
        }

        let updates = await recorder.values()
        #expect(updates.last == .signedIn(accountID: "review@example.com"))
        #expect(await session.recordedRefreshRequests() == [true, false, false])
    }

    @Test func authManagerFailsWhenSignedOutProbeIsFollowedByTransientError() async throws {
        let session = SignedOutThenUnavailableReviewAuthSession()
        let manager = ReviewAuthManager(
            configuration: .init(
                environment: ["HOME": makeTemporaryRoot().path],
                durableAuthMaxAttempts: 2,
                durableAuthRetryDelay: .zero
            ),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        await #expect(throws: ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)) {
            try await manager.beginAuthentication { state in
                await recorder.append(state)
            }
        }

        let updates = await recorder.values()
        #expect(updates.last == .failed(reviewAuthPersistenceFailureMessage))
    }

    @Test func authManagerFailsWhenDedicatedHomeAuthWasNotPersisted() async throws {
        let session = PostLoginDurableCheckReviewAuthSession(
            durableResponse: .init(account: nil, requiresOpenAIAuth: true),
            postLoginRefreshError: NSError(
                domain: "ReviewAuthManagerTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "refresh failed"]
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        await #expect(throws: ReviewAuthError.loginFailed(reviewAuthPersistenceFailureMessage)) {
            try await manager.beginAuthentication { state in
                await recorder.append(state)
            }
        }

        let updates = await recorder.values()
        #expect(updates.last == .failed(reviewAuthPersistenceFailureMessage))
    }

    @Test func authManagerUsesInjectedClockForDurableAuthDeadline() async throws {
        let clock = JumpingReviewClock()
        let session = PostLoginDurableCheckReviewAuthSession(
            durableResponse: .init(account: nil, requiresOpenAIAuth: true),
            refreshedResponse: .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            ),
            postLoginRefreshError: nil
        )
        let manager = ReviewAuthManager(
            configuration: .init(
                environment: ["HOME": makeTemporaryRoot().path],
                startupTimeout: .seconds(2),
                durableAuthRetryDelay: .seconds(1),
                clock: clock
            ),
            sessionFactory: { session }
        )
        let recorder = AuthUpdateRecorder()

        let task = Task<Result<Void, Error>, Never> {
            do {
                try await manager.beginAuthentication { state in
                    await recorder.append(state)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        let result = try await withTestTimeout {
            await task.value
        }

        switch result {
        case .success:
            Issue.record("Expected durable auth verification to fail after the injected clock advanced past the timeout.")
        case .failure(let error):
            #expect(error as? ReviewAuthError == .loginFailed(reviewAuthPersistenceFailureMessage))
        }

        let updates = await recorder.values()
        #expect(updates.last == .failed(reviewAuthPersistenceFailureMessage))
        #expect(clock.sleepCallCount() >= 1)
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
        await recorder.waitUntilContains { state in
            guard let progress = CodexReviewAuthStateAccessors.progress(state) else {
                return false
            }
            return progress.browserURL == nil
                && progress.detail == "Preparing browser sign-in."
        }

        await factory.resume()
        await session.waitForLoginStart()

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
            loginResponse: .chatGPT(
                loginID: "login-browser",
                authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
            )
        )
        let manager = ReviewAuthManager(
            configuration: .init(environment: ["HOME": makeTemporaryRoot().path]),
            sessionFactory: { session }
        )

        let task = Task {
            try await manager.beginAuthentication { _ in }
        }

        await session.waitForLoginStart()

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

    @Test func cliReviewAuthSessionReadAccountCompletesWhenCommandExitsDuringRun() async throws {
        let session = CLIReviewAuthSession(
            configuration: .init(
                codexCommand: "/tmp/fake-codex",
                environment: ["HOME": makeTemporaryRoot().path],
                commandProcessFactory: {
                    ImmediateExitProcess(stdout: "Not logged in\n")
                }
            )
        )

        let response = try await withTestTimeout {
            try await session.readAccount(refreshToken: false)
        }

        #expect(response.account == nil)
        #expect(response.requiresOpenAIAuth)
    }

    @Test func cliReviewAuthSessionLogoutCompletesWhenCommandExitsDuringRun() async throws {
        let session = CLIReviewAuthSession(
            configuration: .init(
                codexCommand: "/tmp/fake-codex",
                environment: ["HOME": makeTemporaryRoot().path],
                commandProcessFactory: {
                    ImmediateExitProcess(stdout: "Signed out\n")
                }
            )
        )

        try await withTestTimeout {
            try await session.logout()
        }
    }

    @Test func cliReviewAuthSessionCloseTreatsCancelledStartupBeforeBrowserURLAsCancelled() async throws {
        let root = makeTemporaryRoot()
        let marker = root.appendingPathComponent("login-started")
        let script = try makeExecutableScript(
            at: root.appendingPathComponent("codex"),
            contents: """
            #!/bin/sh
            touch "\(marker.path)"
            trap 'echo "cancelled during startup" >&2; exit 0' TERM INT
            while true; do
              sleep 1
            done
            """
        )
        let session = CLIReviewAuthSession(
            configuration: .init(
                codexCommand: script.path,
                environment: ["HOME": root.path]
            )
        )

        let task = Task {
            try await session.startLogin(.chatGPT)
        }

        try await waitForFileAppearance(at: marker)

        await session.close()

        await #expect(throws: ReviewAuthError.cancelled) {
            try await task.value
        }
    }

    @Test func fakeReviewAuthSessionBrowserStartReturnsAuthURLAndLoginID() async throws {
        let session = FakeReviewAuthSession(
            readResponses: [],
            loginResponse: .chatGPT(
                loginID: "login-browser",
                authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
            )
        )

        let response = try await session.startLogin(.chatGPT)

        guard case .chatGPT(let loginID, let authURL, _) = response else {
            Issue.record("Expected chatgpt browser response, got \(response)")
            return
        }
        #expect(loginID.isEmpty == false)
        #expect(authURL.contains("/oauth/authorize"))
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

    @Test func cliAuthOutputHelpersExtractBrowserURL() {
        let browserLine = "\u{001B}[94mhttps://auth.openai.com/oauth/authorize?foo=bar\u{001B}[0m"

        #expect(sanitizeCLIAuthOutput(browserLine) == "https://auth.openai.com/oauth/authorize?foo=bar")
        #expect(extractReviewAuthHTTPSURL(from: sanitizeCLIAuthOutput(browserLine)) == "https://auth.openai.com/oauth/authorize?foo=bar")
    }

    @Test func cliAccountReadResponseTreatsSignedOutStatusBeforeGenericLoggedInMatch() throws {
        let response = try makeCLIAccountReadResponse(
            exitCode: 0,
            combinedOutput: "Not logged in",
            storedEmail: "review@example.com",
            storedPlanType: "plus"
        )

        #expect(response.account == nil)
        #expect(response.requiresOpenAIAuth)
    }

    @Test func cliAccountReadResponseUsesStoredAccountForSignedInStatus() throws {
        let response = try makeCLIAccountReadResponse(
            exitCode: 0,
            combinedOutput: "Logged in as review@example.com",
            storedEmail: "review@example.com",
            storedPlanType: "plus"
        )

        guard case .chatGPT(let email, let planType)? = response.account else {
            Issue.record("Expected chatGPT account, got \(String(describing: response.account))")
            return
        }
        #expect(email == "review@example.com")
        #expect(planType == "plus")
        #expect(response.requiresOpenAIAuth == false)
    }
}

private actor AuthUpdateRecorder {
    private var updates: [CodexReviewAuthModel.State] = []
    private let updateSignal = AsyncSignal()

    func append(_ state: CodexReviewAuthModel.State) async {
        updates.append(state)
        await updateSignal.signal()
    }

    func values() -> [CodexReviewAuthModel.State] {
        updates
    }

    func waitUntilContains(
        _ predicate: @escaping @Sendable (CodexReviewAuthModel.State) -> Bool
    ) async {
        if updates.contains(where: predicate) {
            return
        }

        var targetCount = await updateSignal.count() + 1
        while true {
            await updateSignal.wait(untilCount: targetCount)
            if updates.contains(where: predicate) {
                return
            }
            targetCount = await updateSignal.count() + 1
        }
    }
}

private final class JumpingReviewClock: @unchecked Sendable, ReviewClock {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant
    private var sleepCalls = 0

    init(now: ContinuousClock.Instant = ContinuousClock().now) {
        current = now
    }

    var now: ContinuousClock.Instant {
        lock.withLock { current }
    }

    func sleep(until deadline: ContinuousClock.Instant, tolerance _: Duration?) async throws {
        lock.withLock {
            sleepCalls += 1
            current = deadline.advanced(by: .seconds(1))
        }
    }

    func sleepCallCount() -> Int {
        lock.withLock { sleepCalls }
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

    func resume() async {
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
    private var bufferedNotifications: [AppServerServerNotification] = []
    private let loginStartedSignal = AsyncSignal()

    init(
        readResponses: [AppServerAccountReadResponse],
        loginResponse: AppServerLoginAccountResponse = .chatGPT(
            loginID: "login-default",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
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
        await loginStartedSignal.signal()
        return loginResponse
    }

    func cancelLogin(loginID: String) async throws {
        cancelledIDs.append(loginID)
    }

    func logout() async throws {
        logoutCalls += 1
    }

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
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
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
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

    func waitForLoginStart() async {
        await loginStartedSignal.wait()
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }
}

private actor PostLoginDurableCheckReviewAuthSession: ReviewAuthSession {
    private let durableResponse: AppServerAccountReadResponse
    private let refreshedResponse: AppServerAccountReadResponse?
    private let postLoginRefreshError: Error?
    private let durableCheckError: Error?
    private var refreshRequests: [Bool] = []
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var didFailPostLoginRefresh = false

    init(
        durableResponse: AppServerAccountReadResponse,
        refreshedResponse: AppServerAccountReadResponse? = nil,
        postLoginRefreshError: Error?,
        durableCheckError: Error? = nil
    ) {
        self.durableResponse = durableResponse
        self.refreshedResponse = refreshedResponse
        self.postLoginRefreshError = postLoginRefreshError
        self.durableCheckError = durableCheckError
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        refreshRequests.append(refreshToken)
        if refreshToken,
           didFailPostLoginRefresh == false,
           let postLoginRefreshError
        {
            didFailPostLoginRefresh = true
            throw postLoginRefreshError
        }
        if refreshToken == false, let durableCheckError {
            throw durableCheckError
        }
        if refreshToken {
            return refreshedResponse ?? durableResponse
        }
        return durableResponse
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: nil)))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(stream: stream, cancel: {})
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func recordedRefreshRequests() -> [Bool] {
        refreshRequests
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

private actor EventuallyPersistentLoginReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var refreshRequests: [Bool] = []
    private var durableReadCount = 0

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        refreshRequests.append(refreshToken)
        if refreshToken {
            return .init(account: nil, requiresOpenAIAuth: true)
        }

        durableReadCount += 1
        if durableReadCount == 1 {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        return .init(
            account: .chatGPT(email: "review@example.com", planType: "plus"),
            requiresOpenAIAuth: false
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: nil)))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(stream: stream, cancel: {})
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func recordedRefreshRequests() -> [Bool] {
        refreshRequests
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

private actor SignedOutThenUnavailableReviewAuthSession: ReviewAuthSession {
    private var continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation?
    private var bufferedNotifications: [AppServerServerNotification] = []
    private var refreshRequests: [Bool] = []
    private var durableReadCount = 0

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        refreshRequests.append(refreshToken)
        if refreshToken {
            return .init(
                account: .chatGPT(email: "review@example.com", planType: "plus"),
                requiresOpenAIAuth: false
            )
        }

        durableReadCount += 1
        if durableReadCount == 1 {
            return .init(account: nil, requiresOpenAIAuth: true)
        }
        throw NSError(
            domain: "ReviewAuthManagerTests.SignedOutThenUnavailableReviewAuthSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "status unavailable"]
        )
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        _ = params
        buffer(.accountUpdated(.init(authMode: .chatGPT, planType: nil)))
        buffer(.accountLoginCompleted(.init(error: nil, loginID: "login-browser", success: true)))
        return .chatGPT(
            loginID: "login-browser",
            authURL: "https://auth.openai.com/oauth/authorize?foo=bar"
        )
    }

    func cancelLogin(loginID _: String) async throws {}

    func logout() async throws {}

    func notificationStream() async -> AsyncThrowingStreamSubscription<AppServerServerNotification> {
        let (stream, continuation) = AsyncThrowingStream<AppServerServerNotification, Error>.makeStream()
        setContinuation(continuation)
        return .init(stream: stream, cancel: {})
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func recordedRefreshRequests() -> [Bool] {
        refreshRequests
    }

    private func setContinuation(
        _ continuation: AsyncThrowingStream<AppServerServerNotification, Error>.Continuation
    ) {
        self.continuation = continuation
        let bufferedNotifications = self.bufferedNotifications
        self.bufferedNotifications.removeAll(keepingCapacity: false)
        for notification in bufferedNotifications {
            continuation.yield(notification)
        }
    }

    private func buffer(_ notification: AppServerServerNotification) {
        if let continuation {
            continuation.yield(notification)
        } else {
            bufferedNotifications.append(notification)
        }
    }
}

private final class ImmediateExitProcess: Process, @unchecked Sendable {
    private let exitStatus: Int32
    private let stdoutData: Data
    private let stderrData: Data
    private var storedTerminationHandler: (@Sendable (Process) -> Void)?
    private var storedExecutableURL: URL?
    private var storedArguments: [String]?
    private var storedEnvironment: [String: String]?
    private var storedCurrentDirectoryURL: URL?
    private var storedStandardInput: Any?
    private var storedStandardOutput: Any?
    private var storedStandardError: Any?

    init(
        terminationStatus: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) {
        self.exitStatus = terminationStatus
        self.stdoutData = Data(stdout.utf8)
        self.stderrData = Data(stderr.utf8)
        super.init()
    }

    override var terminationStatus: Int32 {
        exitStatus
    }

    override var executableURL: URL? {
        get { storedExecutableURL }
        set { storedExecutableURL = newValue }
    }

    override var arguments: [String]? {
        get { storedArguments }
        set { storedArguments = newValue }
    }

    override var environment: [String: String]? {
        get { storedEnvironment }
        set { storedEnvironment = newValue }
    }

    override var currentDirectoryURL: URL? {
        get { storedCurrentDirectoryURL }
        set { storedCurrentDirectoryURL = newValue }
    }

    override var standardInput: Any? {
        get { storedStandardInput }
        set { storedStandardInput = newValue }
    }

    override var standardOutput: Any? {
        get { storedStandardOutput }
        set { storedStandardOutput = newValue }
    }

    override var standardError: Any? {
        get { storedStandardError }
        set { storedStandardError = newValue }
    }

    override var terminationHandler: (@Sendable (Process) -> Void)? {
        get { storedTerminationHandler }
        set { storedTerminationHandler = newValue }
    }

    override func run() throws {
        write(stdoutData, to: storedStandardOutput)
        write(stderrData, to: storedStandardError)
        storedTerminationHandler?(self)
    }

    override func waitUntilExit() {}

    override func terminate() {}

    override func interrupt() {}

    private func write(_ data: Data, to destination: Any?) {
        guard let pipe = destination as? Pipe else {
            return
        }
        if data.isEmpty == false {
            pipe.fileHandleForWriting.write(data)
        }
        pipe.fileHandleForWriting.closeFile()
    }
}

private func withTestTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TestFailure("timed out waiting for operation")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TestFailure("timed out waiting for operation")
        }
        return result
    }
}

private func waitForFileAppearance(
    at fileURL: URL,
    timeout: Duration = .seconds(2)
) async throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
        return
    }

    let monitor = try DirectoryChangeMonitor(directoryURL: fileURL.deletingLastPathComponent())
    defer { monitor.cancel() }

    try await withTestTimeout(timeout) {
        var observedEventCount = await monitor.eventCount()
        while FileManager.default.fileExists(atPath: fileURL.path) == false {
            await monitor.waitForChange(after: observedEventCount)
            observedEventCount = await monitor.eventCount()
        }
    }
}

private func makeTemporaryRoot() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeExecutableScript(
    at url: URL,
    contents: String
) throws -> URL {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
    return url
}

private struct TestFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

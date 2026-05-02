import AppKit
import AuthenticationServices
import Foundation
import ReviewAppServerIntegration

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

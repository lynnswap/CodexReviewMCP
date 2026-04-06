import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewAuthModel {
    public struct Progress: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var browserURL: String?

        public init(
            title: String,
            detail: String,
            browserURL: String? = nil
        ) {
            self.title = title
            self.detail = detail
            self.browserURL = browserURL
        }
    }

    public enum State: Sendable, Equatable {
        case signedOut
        case signingIn(Progress)
        case signedIn(accountID: String?)
        case failed(String)
    }

    public package(set) var state: State = .signedOut

    @ObservationIgnored private let backend: any CodexReviewStoreBackend


    public var progress: Progress? {
        guard case .signingIn(let progress) = state else {
            return nil
        }
        return progress
    }

    public var isAuthenticating: Bool {
        if case .signingIn = state {
            return true
        }
        return false
    }

    public var isAuthenticated: Bool {
        if case .signedIn = state {
            return true
        }
        return false
    }

    package init(backend: any CodexReviewStoreBackend) {
        self.backend = backend
    }

    public func refresh() async {
        await backend.refreshAuthState(auth: self)
    }

    public func beginAuthentication() async {
        await backend.beginAuthentication(auth: self)
    }

    public func cancelAuthentication() async {
        await backend.cancelAuthentication(auth: self)
    }

    public func logout() async {
        await backend.logout(auth: self)
    }

    package func updateState(_ state: State) {
        self.state = state
    }
}

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

    public struct State: Sendable, Equatable {
        public var isAuthenticated: Bool
        public var accountID: String?
        public var progress: Progress?
        public var errorMessage: String?

        public init(
            isAuthenticated: Bool = false,
            accountID: String? = nil,
            progress: Progress? = nil,
            errorMessage: String? = nil
        ) {
            self.isAuthenticated = isAuthenticated
            self.accountID = isAuthenticated ? accountID : nil
            self.progress = progress
            self.errorMessage = progress == nil ? errorMessage : nil
        }

        public static let signedOut = State()

        public static func signedIn(accountID: String?) -> State {
            State(
                isAuthenticated: true,
                accountID: accountID
            )
        }

        public static func signingIn(_ progress: Progress) -> State {
            State(progress: progress)
        }

        public static func signingIn(
            _ progress: Progress,
            preserving previous: State
        ) -> State {
            State(
                isAuthenticated: previous.isAuthenticated,
                accountID: previous.accountID,
                progress: progress
            )
        }

        public static func failed(
            _ message: String,
            isAuthenticated: Bool = false,
            accountID: String? = nil
        ) -> State {
            State(
                isAuthenticated: isAuthenticated,
                accountID: accountID,
                errorMessage: message
            )
        }
    }

    public package(set) var state: State = .signedOut

    @ObservationIgnored private let backend: any CodexReviewStoreBackend

    public var progress: Progress? {
        state.progress
    }

    public var isAuthenticating: Bool {
        state.progress != nil
    }

    public var isAuthenticated: Bool {
        state.isAuthenticated
    }

    public var accountID: String? {
        state.accountID
    }

    public var errorMessage: String? {
        state.errorMessage
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

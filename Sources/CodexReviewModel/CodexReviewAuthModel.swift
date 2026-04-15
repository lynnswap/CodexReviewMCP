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

    public enum Phase: Sendable, Equatable {
        case signedOut
        case signingIn(Progress)
        case failed(message: String)
    }

    public package(set) var phase: Phase = .signedOut
    public package(set) var account: CodexAccount?

    @ObservationIgnored private let controller: any CodexReviewAuthControlling

    public var progress: Progress? {
        guard case .signingIn(let progress) = phase else {
            return nil
        }
        return progress
    }

    public var isAuthenticating: Bool {
        progress != nil
    }

    public var isAuthenticated: Bool {
        account != nil
    }

    public var errorMessage: String? {
        guard case .failed(let message) = phase else {
            return nil
        }
        return message
    }

    package init(controller: any CodexReviewAuthControlling) {
        self.controller = controller
    }

    public func refresh() async {
        await controller.refresh(auth: self)
    }

    public func beginAuthentication() async {
        await controller.beginAuthentication(auth: self)
    }

    public func cancelAuthentication() async {
        await controller.cancelAuthentication(auth: self)
    }

    public func logout() async {
        await controller.logout(auth: self)
    }

    package func startStartupRefresh() {
        controller.startStartupRefresh(auth: self)
    }

    package func cancelStartupRefresh() {
        controller.cancelStartupRefresh()
    }

    package func reconcileAuthenticatedSession(
        serverIsRunning: Bool,
        runtimeGeneration: Int
    ) async {
        await controller.reconcileAuthenticatedSession(
            auth: self,
            serverIsRunning: serverIsRunning,
            runtimeGeneration: runtimeGeneration
        )
    }

    package func updatePhase(_ phase: Phase) {
        self.phase = phase
    }

    package func updateAccount(_ account: CodexAccount?) {
        self.account = account
    }
}

import Foundation
import ReviewAppServerIntegration
import ReviewInfrastructure

actor LegacyProbeScopedReviewAuthSession: ReviewAuthSession {
    private let base: any ReviewAuthSession
    private let fileSystem: ReviewFileSystemClient
    private let sharedAuthURL: URL
    private let probeAuthURL: URL
    private let originalSharedAuthData: Data?
    private let originalSharedAuthEmail: String?
    private var restoredSharedAuth = false

    init(
        base: any ReviewAuthSession,
        sharedDependencies: ReviewCoreDependencies,
        probeDependencies: ReviewCoreDependencies
    ) async throws {
        self.base = base
        fileSystem = sharedDependencies.fileSystem
        sharedAuthURL = sharedDependencies.paths.reviewAuthURL()
        probeAuthURL = probeDependencies.paths.reviewAuthURL()
        originalSharedAuthData = try? sharedDependencies.fileSystem.readData(sharedAuthURL)
        originalSharedAuthEmail = extractedAuthSnapshotEmail(from: originalSharedAuthData)
    }

    func readAccount(refreshToken: Bool) async throws -> AppServerAccountReadResponse {
        let response = try await base.readAccount(refreshToken: refreshToken)
        if case .chatGPT(let email, _)? = response.account,
           let email = email.nilIfEmpty
        {
            let currentSharedAuthData = try? fileSystem.readData(sharedAuthURL)
            if currentSharedAuthData != nil,
               (
                   currentSharedAuthData != originalSharedAuthData
                       || originalSharedAuthEmail == email
               )
            {
                copySharedAuthToProbe()
            }
        } else if response.requiresOpenAIAuth {
            removeProbeAuth()
        }
        return response
    }

    func startLogin(_ params: AppServerLoginAccountParams) async throws -> AppServerLoginAccountResponse {
        try await base.startLogin(params)
    }

    func cancelLogin(loginID: String) async throws {
        try await base.cancelLogin(loginID: loginID)
    }

    func logout() async throws {
        try await base.logout()
        removeProbeAuth()
        restoreSharedAuthIfNeeded()
    }

    func notificationStream() async -> AsyncThrowingStream<AppServerServerNotification, Error> {
        await base.notificationStream()
    }

    func close() async {
        await base.close()
        restoreSharedAuthIfNeeded()
    }

    private func copySharedAuthToProbe() {
        guard let data = try? fileSystem.readData(sharedAuthURL) else {
            return
        }
        try? fileSystem.createDirectory(probeAuthURL.deletingLastPathComponent(), true)
        try? fileSystem.writeData(data, probeAuthURL, [.atomic])
    }

    private func removeProbeAuth() {
        try? fileSystem.removeItem(probeAuthURL)
    }

    private func restoreSharedAuthIfNeeded() {
        guard restoredSharedAuth == false else {
            return
        }
        restoredSharedAuth = true
        if let originalSharedAuthData {
            try? fileSystem.createDirectory(sharedAuthURL.deletingLastPathComponent(), true)
            try? fileSystem.writeData(originalSharedAuthData, sharedAuthURL, [.atomic])
        } else {
            try? fileSystem.removeItem(sharedAuthURL)
        }
    }
}

private func makeReviewAuthToken(payload: [String: Any]) -> String {
    let header = ["alg": "none", "typ": "JWT"]
    let headerData = try? JSONSerialization.data(withJSONObject: header)
    let payloadData = try? JSONSerialization.data(withJSONObject: payload)
    return "\(makeReviewAuthTokenComponent(headerData ?? Data())).\(makeReviewAuthTokenComponent(payloadData ?? Data()))."
}

private func makeReviewAuthTokenComponent(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func extractedAuthSnapshotEmail(from authData: Data?) -> String? {
    guard let authData,
          let object = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any],
          let idToken = tokens["id_token"] as? String
    else {
        return nil
    }
    let components = idToken.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count >= 2,
          let payloadData = decodeBase64URL(String(components[1])),
          let payloadObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
          let email = payloadObject["email"] as? String
    else {
        return nil
    }
    return email.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private func decodeBase64URL(_ value: String) -> Data? {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder != 0 {
        normalized.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: normalized)
}

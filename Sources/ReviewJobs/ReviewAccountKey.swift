import Foundation

public func normalizedReviewAccountKey(email: String) -> String {
    let normalizedEmail = email
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard let data = normalizedEmail.data(using: .utf8) else {
        return normalizedEmail
    }
    return data
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

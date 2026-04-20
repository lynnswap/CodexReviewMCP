import Foundation

public func normalizedReviewAccountEmail(email: String) -> String {
    email
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

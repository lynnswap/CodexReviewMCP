import Foundation

public func normalizedReviewAccountKey(email: String) -> String {
    email
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

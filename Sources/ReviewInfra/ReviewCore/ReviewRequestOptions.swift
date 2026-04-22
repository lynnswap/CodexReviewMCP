import Foundation
import ReviewDomain

package typealias ReviewRequestOptions = ReviewJobRequest

package extension ReviewJobRequest {
    func validated() throws -> Self {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCWD.isEmpty == false else {
            throw ReviewError.invalidArguments("`cwd` is required.")
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw ReviewError.invalidArguments("`timeoutSeconds` must be a positive integer.")
        }
        var copy = self
        copy.cwd = trimmedCWD
        copy.target = try target.validated()
        return copy
    }

    var targetSummary: String {
        switch target {
        case .uncommittedChanges:
            return "Uncommitted changes"
        case .baseBranch(let branch):
            return "Base branch: \(branch)"
        case .commit(let sha, let title):
            if let title, title.isEmpty == false {
                return title
            }
            return "Commit: \(String(sha.prefix(12)))"
        case .custom(let instructions):
            let firstLine = instructions
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Custom review"
            if firstLine.isEmpty {
                return "Custom review"
            }
            if firstLine.count > 80 {
                return String(firstLine.prefix(77)) + "..."
            }
            return firstLine
        }
    }
}

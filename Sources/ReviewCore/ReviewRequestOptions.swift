import Foundation
import ReviewJobs

package typealias ReviewRequestOptions = ReviewJobRequest

package extension ReviewJobRequest {
    func validated() throws -> Self {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCWD.isEmpty == false else {
            throw ReviewError.invalidArguments("`cwd` is required.")
        }
        if commit != nil, base != nil || uncommitted {
            throw ReviewError.invalidArguments("`commit` cannot be combined with `base` or `uncommitted`.")
        }
        if base != nil, uncommitted {
            throw ReviewError.invalidArguments("`base` cannot be combined with `uncommitted`.")
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            throw ReviewError.invalidArguments("`timeoutSeconds` must be a positive integer.")
        }
        var copy = self
        copy.cwd = trimmedCWD
        return copy
    }

    var targetSummary: String {
        if uncommitted {
            return "Uncommitted changes"
        }
        if let base, base.isEmpty == false {
            return "Base branch: \(base)"
        }
        if let commit, commit.isEmpty == false {
            if let title, title.isEmpty == false {
                return title
            }
            return "Commit: \(String(commit.prefix(12)))"
        }
        if let prompt, prompt.isEmpty == false {
            let firstLine = prompt
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
        return "Review"
    }
}

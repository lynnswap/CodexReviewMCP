import Foundation
import ReviewJobs

package struct ReviewStartRequest: Codable, Hashable, Sendable {
    package var cwd: String
    package var target: ReviewTarget
    package var model: String?

    package init(cwd: String, target: ReviewTarget, model: String? = nil) {
        self.cwd = cwd
        self.target = target
        self.model = model
    }

    package func validated() throws -> Self {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCWD.isEmpty == false else {
            throw ReviewError.invalidArguments("`cwd` is required.")
        }
        var copy = self
        copy.cwd = trimmedCWD
        copy.target = try target.validated()
        copy.model = model?.nilIfEmpty
        return copy
    }

    package func reviewRequestOptions() -> ReviewRequestOptions {
        ReviewRequestOptions(cwd: cwd, target: target, model: model)
    }
}

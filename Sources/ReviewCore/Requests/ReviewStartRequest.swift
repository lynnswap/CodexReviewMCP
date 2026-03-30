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
        switch target {
        case .uncommittedChanges:
            return ReviewRequestOptions(
                cwd: cwd,
                uncommitted: true,
                model: model
            )
        case .baseBranch(let branch):
            return ReviewRequestOptions(
                cwd: cwd,
                base: branch,
                model: model
            )
        case .commit(let sha, let title):
            return ReviewRequestOptions(
                cwd: cwd,
                commit: sha,
                title: title,
                model: model
            )
        case .custom(let instructions):
            return ReviewRequestOptions(
                cwd: cwd,
                prompt: instructions,
                model: model
            )
        }
    }
}

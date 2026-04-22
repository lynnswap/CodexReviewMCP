import Foundation
import Observation
import ReviewRuntime
import ReviewDomain

@MainActor
@Observable
public final class CodexReviewWorkspace: Hashable {
    public nonisolated let cwd: String
    package var isExpanded: Bool
    public package(set) var jobs: [CodexReviewJob]

    public nonisolated var displayTitle: String {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return title.isEmpty ? cwd : title
    }

    public init(cwd: String, jobs: [CodexReviewJob]) {
        self.cwd = cwd
        self.isExpanded = true
        self.jobs = jobs
    }

    public nonisolated static func == (lhs: CodexReviewWorkspace, rhs: CodexReviewWorkspace) -> Bool {
        lhs.cwd == rhs.cwd
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(cwd)
    }
}

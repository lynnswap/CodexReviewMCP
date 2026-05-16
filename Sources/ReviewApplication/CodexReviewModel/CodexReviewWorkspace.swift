import Foundation
import Observation
import ReviewDomain

@MainActor
@Observable
public final class CodexReviewWorkspace: Hashable {
    public nonisolated let cwd: String
    public package(set) var sortOrder: Double
    package var isExpanded: Bool
    public package(set) var jobs: [CodexReviewJob]

    public nonisolated var displayTitle: String {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return title.isEmpty ? cwd : title
    }

    public init(cwd: String, sortOrder: Double = 0, jobs: [CodexReviewJob]) {
        self.cwd = cwd
        self.sortOrder = sortOrder
        self.isExpanded = true
        self.jobs = jobs
        normalizeJobSortOrders()
    }

    package var orderedJobs: [CodexReviewJob] {
        jobs.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.id < $1.id
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    package func replaceJobs(_ jobs: [CodexReviewJob]) {
        self.jobs = jobs
        normalizeJobSortOrders()
    }

    package func insertJobAtFront(_ job: CodexReviewJob) {
        job.sortOrder = (orderedJobs.first?.sortOrder ?? 0) - 1
        jobs.append(job)
    }

    package func normalizeJobSortOrders() {
        for (index, job) in jobs.enumerated() {
            job.sortOrder = Double(index)
        }
    }

    public nonisolated static func == (lhs: CodexReviewWorkspace, rhs: CodexReviewWorkspace) -> Bool {
        lhs.cwd == rhs.cwd
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(cwd)
    }
}

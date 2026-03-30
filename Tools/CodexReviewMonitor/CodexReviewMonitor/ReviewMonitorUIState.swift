import CodexReviewMCP
import Observation

@MainActor
@Observable
final class ReviewMonitorUIState {
    var selectedJobEntry: CodexReviewJob?
}

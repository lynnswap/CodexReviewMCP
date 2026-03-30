import CodexReviewMCP
import Observation

@MainActor
@Observable
final class ReviewMonitorUIState {
    weak var selectedJobEntry: CodexReviewJob?
}

import Observation
import ReviewRuntime

@MainActor
@Observable
final class ReviewMonitorUIState {
    var selectedJobEntry: CodexReviewJob?
}

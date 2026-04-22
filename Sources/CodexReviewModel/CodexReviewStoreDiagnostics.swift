import Foundation
import ReviewDomain

public enum CodexReviewStoreTestEnvironment {
    public static let uiTestModeKey = "CODEX_REVIEW_MONITOR_UI_TEST_MODE"
    public static let mockJobsKey = "CODEX_REVIEW_MONITOR_MOCK_JOBS"
    public static let portKey = "CODEX_REVIEW_MONITOR_TEST_PORT"
    public static let codexCommandKey = "CODEX_REVIEW_MONITOR_TEST_CODEX_COMMAND"
    public static let diagnosticsPathKey = "CODEX_REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    public static let mockJobsArgument = "--codex-review-monitor-mock-jobs"
    public static let portArgument = "--codex-review-monitor-test-port"
    public static let codexCommandArgument = "--codex-review-monitor-test-codex-command"
    public static let diagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"
}

struct CodexReviewStoreDiagnosticsSnapshot: Encodable {
    struct Job: Encodable {
        var status: String
        var summary: String
        var logText: String
        var rawLogText: String
    }

    var serverState: String
    var failureMessage: String?
    var serverURL: String?
    var childRuntimePath: String?
    var jobs: [Job]
}

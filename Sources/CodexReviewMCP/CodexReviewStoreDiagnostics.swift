import Foundation

enum CodexReviewStoreTestEnvironment {
    static let portKey = "CODEX_REVIEW_MONITOR_TEST_PORT"
    static let codexCommandKey = "CODEX_REVIEW_MONITOR_TEST_CODEX_COMMAND"
    static let diagnosticsPathKey = "CODEX_REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    static let portArgument = "--codex-review-monitor-test-port"
    static let codexCommandArgument = "--codex-review-monitor-test-codex-command"
    static let diagnosticsPathArgument = "--codex-review-monitor-test-diagnostics-path"
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

package struct ReviewJobRequest: Codable, Hashable, Sendable {
    package var cwd: String
    package var target: ReviewTarget
    package var timeoutSeconds: Int?

    package init(
        cwd: String,
        target: ReviewTarget,
        timeoutSeconds: Int? = nil
    ) {
        self.cwd = cwd
        self.target = target
        self.timeoutSeconds = timeoutSeconds
    }
}

package struct ReviewJobRequest: Codable, Hashable, Sendable {
    package var cwd: String
    package var target: ReviewTarget
    package var model: String?
    package var timeoutSeconds: Int?

    package init(
        cwd: String,
        target: ReviewTarget,
        model: String? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.cwd = cwd
        self.target = target
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
}

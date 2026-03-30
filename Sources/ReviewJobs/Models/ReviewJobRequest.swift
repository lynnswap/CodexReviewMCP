package struct ReviewJobRequest: Codable, Hashable, Sendable {
    package var cwd: String
    package var prompt: String?
    package var base: String?
    package var commit: String?
    package var uncommitted: Bool
    package var title: String?
    package var model: String?
    package var ephemeral: Bool
    package var configOverrides: [String]
    package var extraArgs: [String]
    package var timeoutSeconds: Int?
    package var keepArtifacts: Bool

    package init(
        cwd: String,
        prompt: String? = nil,
        base: String? = nil,
        commit: String? = nil,
        uncommitted: Bool = false,
        title: String? = nil,
        model: String? = nil,
        ephemeral: Bool = false,
        configOverrides: [String] = [],
        extraArgs: [String] = [],
        timeoutSeconds: Int? = nil,
        keepArtifacts: Bool = false
    ) {
        self.cwd = cwd
        self.prompt = prompt
        self.base = base
        self.commit = commit
        self.uncommitted = uncommitted
        self.title = title
        self.model = model
        self.ephemeral = ephemeral
        self.configOverrides = configOverrides
        self.extraArgs = extraArgs
        self.timeoutSeconds = timeoutSeconds
        self.keepArtifacts = keepArtifacts
    }
}

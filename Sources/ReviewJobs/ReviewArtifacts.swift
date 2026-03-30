package struct ReviewArtifacts: Codable, Hashable, Sendable {
    package var eventsPath: String?
    package var logPath: String?
    package var lastMessagePath: String?

    package init(eventsPath: String?, logPath: String?, lastMessagePath: String?) {
        self.eventsPath = eventsPath
        self.logPath = logPath
        self.lastMessagePath = lastMessagePath
    }
}

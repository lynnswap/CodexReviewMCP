import Darwin
import Foundation

package struct ReviewDiscoveryClient: Sendable {
    package var dependencies: ReviewCoreDependencies

    package init(dependencies: ReviewCoreDependencies = .live()) {
        self.dependencies = dependencies
    }

    package var defaultFileURL: URL {
        dependencies.paths.discoveryFileURL()
    }

    package func makeRecord(
        host: String,
        port: Int,
        pid: Int? = nil,
        endpointPath: String = codexReviewDefaultEndpointPath
    ) -> LiveEndpointRecord? {
        let pid = pid ?? dependencies.process.currentProcessIdentifier()
        guard port > 0 else {
            return nil
        }
        guard let url = makeURL(host: host, port: port, endpointPath: endpointPath),
              let serverStartTime = dependencies.process.processStartTime(pid_t(pid))
        else {
            return nil
        }
        return LiveEndpointRecord(
            url: url.absoluteString,
            host: host,
            port: port,
            pid: pid,
            serverStartTime: serverStartTime,
            updatedAt: dependencies.dateNow(),
            executableName: dependencies.process.currentExecutableName()
        )
    }

    package func write(_ record: LiveEndpointRecord, to overrideURL: URL? = nil) throws {
        let fileURL = overrideURL ?? defaultFileURL
        try ensureParentDirectory(for: fileURL)
        try dependencies.fileSystem.writeData(
            try makeEncoder().encode(record),
            fileURL,
            [.atomic]
        )
    }

    @discardableResult
    package func writeIfOwned(_ record: LiveEndpointRecord, to overrideURL: URL? = nil) throws -> Bool {
        let fileURL = overrideURL ?? defaultFileURL
        guard let current = loadRecord(from: fileURL),
              ownsRecord(current, pid: record.pid, serverStartTime: record.serverStartTime)
        else {
            return false
        }
        try write(record, to: fileURL)
        return true
    }

    package func read(from overrideURL: URL? = nil) -> LiveEndpointRecord? {
        guard let record = loadRecord(from: overrideURL ?? defaultFileURL),
              isLiveRecord(record)
        else {
            return nil
        }
        return record
    }

    package func readPersisted(from overrideURL: URL? = nil) -> LiveEndpointRecord? {
        loadRecord(from: overrideURL ?? defaultFileURL)
    }

    package func readOwnedRecord(
        pid: Int,
        serverStartTime: ProcessStartTime,
        from overrideURL: URL? = nil
    ) -> LiveEndpointRecord? {
        let fileURL = overrideURL ?? defaultFileURL
        guard let record = loadRecord(from: fileURL),
              ownsRecord(record, pid: pid, serverStartTime: serverStartTime)
        else {
            return nil
        }
        return record
    }

    package func remove(at overrideURL: URL? = nil) {
        try? dependencies.fileSystem.removeItem(overrideURL ?? defaultFileURL)
    }

    package func removeIfOwned(
        pid: Int,
        url: URL?,
        serverStartTime: ProcessStartTime,
        at overrideURL: URL? = nil
    ) {
        let fileURL = overrideURL ?? defaultFileURL
        guard let record = loadRecord(from: fileURL) else {
            return
        }
        guard record.pid == pid else {
            return
        }
        if let url, record.url != url.absoluteString {
            return
        }
        guard record.serverStartTime == serverStartTime else {
            return
        }
        try? dependencies.fileSystem.removeItem(fileURL)
    }

    package func makeURL(host: String, port: Int, endpointPath: String) -> URL? {
        ReviewDiscovery.makeURL(host: host, port: port, endpointPath: endpointPath)
    }

    package func isMatchingExecutable(_ pid: Int, expectedName: String?) -> Bool {
        dependencies.process.isMatchingExecutable(pid, expectedName)
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        let homeURL = fileURL.deletingLastPathComponent()
        if homeURL.lastPathComponent == ".codex_review" {
            try ensureReviewHomeScaffold(at: homeURL)
        } else {
            try dependencies.fileSystem.createDirectory(homeURL, true)
        }
    }

    private func ensureReviewHomeScaffold(at homeURL: URL) throws {
        try dependencies.fileSystem.createDirectory(homeURL, true)
        try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("config.toml"))
        try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("AGENTS.md"))
    }

    private func createEmptyFileIfMissing(at url: URL) throws {
        guard dependencies.fileSystem.fileExists(url.path) == false else {
            return
        }
        try dependencies.fileSystem.writeData(Data(), url, [])
    }

    private func loadRecord(from fileURL: URL) -> LiveEndpointRecord? {
        guard let data = try? dependencies.fileSystem.readData(fileURL) else {
            return nil
        }
        return try? makeDecoder().decode(LiveEndpointRecord.self, from: data)
    }

    private func isLiveRecord(_ record: LiveEndpointRecord) -> Bool {
        guard dependencies.process.isProcessAlive(pid_t(record.pid)) else {
            return false
        }
        guard dependencies.process.processStartTime(pid_t(record.pid)) == record.serverStartTime else {
            return false
        }
        return dependencies.process.isMatchingExecutable(record.pid, record.executableName)
    }

    private func ownsRecord(
        _ record: LiveEndpointRecord,
        pid: Int,
        serverStartTime: ProcessStartTime
    ) -> Bool {
        record.pid == pid && record.serverStartTime == serverStartTime
    }
}

package struct ReviewRuntimeStateClient: Sendable {
    package var dependencies: ReviewCoreDependencies

    package init(dependencies: ReviewCoreDependencies = .live()) {
        self.dependencies = dependencies
    }

    package var defaultFileURL: URL {
        dependencies.paths.runtimeStateFileURL()
    }

    package func write(_ record: ReviewRuntimeStateRecord, to overrideURL: URL? = nil) throws {
        let fileURL = overrideURL ?? defaultFileURL
        try ensureParentDirectory(for: fileURL)
        try dependencies.fileSystem.writeData(
            try makeEncoder().encode(record),
            fileURL,
            [.atomic]
        )
    }

    package func read(from overrideURL: URL? = nil) -> ReviewRuntimeStateRecord? {
        let fileURL = overrideURL ?? defaultFileURL
        guard let data = try? dependencies.fileSystem.readData(fileURL) else {
            return nil
        }
        return try? makeDecoder().decode(ReviewRuntimeStateRecord.self, from: data)
    }

    package func remove(at overrideURL: URL? = nil) {
        try? dependencies.fileSystem.removeItem(overrideURL ?? defaultFileURL)
    }

    package func removeIfOwned(
        serverPID: Int,
        serverStartTime: ProcessStartTime,
        at overrideURL: URL? = nil
    ) {
        let fileURL = overrideURL ?? defaultFileURL
        guard let record = read(from: fileURL) else {
            return
        }
        guard record.serverPID == serverPID, record.serverStartTime == serverStartTime else {
            return
        }
        try? dependencies.fileSystem.removeItem(fileURL)
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        let homeURL = fileURL.deletingLastPathComponent()
        if homeURL.lastPathComponent == ".codex_review" {
            try dependencies.fileSystem.createDirectory(homeURL, true)
            try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("config.toml"))
            try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("AGENTS.md"))
        } else {
            try dependencies.fileSystem.createDirectory(homeURL, true)
        }
    }

    private func createEmptyFileIfMissing(at url: URL) throws {
        guard dependencies.fileSystem.fileExists(url.path) == false else {
            return
        }
        try dependencies.fileSystem.writeData(Data(), url, [])
    }
}

package struct ReviewLocalConfigClient: Sendable {
    package var dependencies: ReviewCoreDependencies

    package init(dependencies: ReviewCoreDependencies = .live()) {
        self.dependencies = dependencies
    }

    package func load() throws -> ReviewLocalConfig {
        let (fileURL, content) = try loadContent()
        return try parseReviewLocalConfig(content, sourcePath: fileURL.path)
    }

    package func loadPresence() throws -> ReviewLocalConfigPresence {
        let (_, content) = try loadContent()
        return parseReviewLocalConfigPresence(content)
    }

    private func loadContent() throws -> (URL, String) {
        let fileURL = dependencies.paths.reviewConfigURL()
        do {
            try ensureReviewHomeScaffold()
        } catch {
            throw ReviewLocalConfigError.unreadable(path: fileURL.path, message: error.localizedDescription)
        }

        do {
            return (fileURL, try dependencies.fileSystem.readString(fileURL, .utf8))
        } catch {
            throw ReviewLocalConfigError.unreadable(path: fileURL.path, message: error.localizedDescription)
        }
    }

    private func ensureReviewHomeScaffold() throws {
        let homeURL = dependencies.paths.reviewHomeURL()
        try dependencies.fileSystem.createDirectory(homeURL, true)
        try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("config.toml"))
        try createEmptyFileIfMissing(at: homeURL.appendingPathComponent("AGENTS.md"))
    }

    private func createEmptyFileIfMissing(at url: URL) throws {
        guard dependencies.fileSystem.fileExists(url.path) == false else {
            return
        }
        try dependencies.fileSystem.writeData(Data(), url, [])
    }
}


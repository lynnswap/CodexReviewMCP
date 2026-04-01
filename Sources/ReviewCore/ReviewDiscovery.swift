import Darwin
import Foundation

package struct ReviewDiscoveryRecord: Codable, Sendable {
    package var url: String
    package var host: String
    package var port: Int
    package var pid: Int
    package var updatedAt: Date
    package var executableName: String?
}

package enum ReviewDiscovery {
    package static var defaultFileURL: URL {
        ReviewHomePaths.discoveryFileURL()
    }

    package static func candidateFileURLs(for overrideURL: URL? = nil) -> [URL] {
        if let overrideURL {
            return [overrideURL]
        }

        let legacyURL = ReviewHomePaths.legacyDiscoveryFileURL()
        if legacyURL.path == defaultFileURL.path {
            return [defaultFileURL]
        }
        return [defaultFileURL, legacyURL]
    }

    package static func makeRecord(
        host: String,
        port: Int,
        pid: Int,
        endpointPath: String = ReviewDefaults.shared.server.endpointPath
    ) -> ReviewDiscoveryRecord? {
        guard port > 0 else { return nil }
        guard let url = makeURL(host: host, port: port, endpointPath: endpointPath) else {
            return nil
        }
        return ReviewDiscoveryRecord(
            url: url.absoluteString,
            host: host,
            port: port,
            pid: pid,
            updatedAt: Date(),
            executableName: currentExecutableName()
        )
    }

    package static func write(_ record: ReviewDiscoveryRecord, to overrideURL: URL? = nil) throws {
        let fileURL = overrideURL ?? defaultFileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: fileURL, options: [.atomic])
    }

    package static func read(from overrideURL: URL? = nil) -> ReviewDiscoveryRecord? {
        read(fromCandidateURLs: candidateFileURLs(for: overrideURL))
    }

    package static func read(fromCandidateURLs fileURLs: [URL]) -> ReviewDiscoveryRecord? {
        for fileURL in fileURLs {
            if let record = validatedRecord(from: fileURL) {
                return record
            }
        }
        return nil
    }

    private static func validatedRecord(from fileURL: URL) -> ReviewDiscoveryRecord? {
        guard let record = loadRecord(from: fileURL) else {
            return nil
        }
        guard ReviewCore_isProcessAlive(record.pid) else {
            return nil
        }
        guard isMatchingExecutable(record.pid, expectedName: record.executableName) else {
            return nil
        }
        return record
    }

    package static func remove(at overrideURL: URL? = nil) {
        remove(atFileURLs: candidateFileURLs(for: overrideURL))
    }

    package static func remove(atFileURLs fileURLs: [URL]) {
        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    package static func removeIfOwned(pid: Int, url: URL?, at overrideURL: URL? = nil) {
        removeIfOwned(pid: pid, url: url, atFileURLs: candidateFileURLs(for: overrideURL))
    }

    package static func removeIfOwned(pid: Int, url: URL?, atFileURLs fileURLs: [URL]) {
        for fileURL in fileURLs {
            guard let record = loadRecord(from: fileURL) else {
                continue
            }
            guard record.pid == pid else {
                continue
            }
            if let url, record.url != url.absoluteString {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func ReviewCore_isProcessAlive(_ pid: Int) -> Bool {
        isProcessAlive(pid_t(pid))
    }

    package static func makeURL(host: String, port: Int, endpointPath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = endpointPath.hasPrefix("/") ? endpointPath : "/\(endpointPath)"
        if let url = components.url {
            return url
        }
        let normalizedHost = host.contains(":") ? "[\(host)]" : host
        let normalizedPath = endpointPath.hasPrefix("/") ? endpointPath : "/\(endpointPath)"
        return URL(string: "http://\(normalizedHost):\(port)\(normalizedPath)")
    }

    private static func loadRecord(from fileURL: URL) -> ReviewDiscoveryRecord? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReviewDiscoveryRecord.self, from: data)
    }

    private static func currentExecutableName() -> String? {
        ProcessInfo.processInfo.arguments.first.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    private static func isMatchingExecutable(_ pid: Int, expectedName: String?) -> Bool {
        guard let expectedName, expectedName.isEmpty == false else {
            return true
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard result > 0 else {
            return false
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent == expectedName
    }
}

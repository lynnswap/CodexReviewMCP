import Darwin
import Foundation

package struct LiveEndpointRecord: Codable, Sendable, Equatable {
    package var url: String
    package var host: String
    package var port: Int
    package var pid: Int
    package var serverStartTime: ProcessStartTime
    package var updatedAt: Date
    package var executableName: String?

    package init(
        url: String,
        host: String,
        port: Int,
        pid: Int,
        serverStartTime: ProcessStartTime,
        updatedAt: Date,
        executableName: String?
    ) {
        self.url = url
        self.host = host
        self.port = port
        self.pid = pid
        self.serverStartTime = serverStartTime
        self.updatedAt = updatedAt
        self.executableName = executableName
    }
}

package enum ReviewDiscovery {
    package static var defaultFileURL: URL {
        ReviewHomePaths.discoveryFileURL()
    }

    package static func makeRecord(
        host: String,
        port: Int,
        pid: Int,
        endpointPath: String = ReviewDefaults.shared.server.endpointPath
    ) -> LiveEndpointRecord? {
        guard port > 0 else {
            return nil
        }
        guard let url = makeURL(host: host, port: port, endpointPath: endpointPath),
              let serverStartTime = processStartTime(of: pid_t(pid))
        else {
            return nil
        }
        return LiveEndpointRecord(
            url: url.absoluteString,
            host: host,
            port: port,
            pid: pid,
            serverStartTime: serverStartTime,
            updatedAt: Date(),
            executableName: currentExecutableName()
        )
    }

    package static func write(_ record: LiveEndpointRecord, to overrideURL: URL? = nil) throws {
        let fileURL = overrideURL ?? defaultFileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeEncoder().encode(record).write(to: fileURL, options: [.atomic])
    }

    @discardableResult
    package static func writeIfOwned(
        _ record: LiveEndpointRecord,
        to overrideURL: URL? = nil
    ) throws -> Bool {
        let fileURL = overrideURL ?? defaultFileURL
        guard let current = loadRecord(from: fileURL),
              ownsRecord(
                current,
                pid: record.pid,
                serverStartTime: record.serverStartTime
              )
        else {
            return false
        }
        try write(record, to: fileURL)
        return true
    }

    package static func read(from overrideURL: URL? = nil) -> LiveEndpointRecord? {
        guard let record = loadRecord(from: overrideURL ?? defaultFileURL),
              isLiveRecord(record)
        else {
            return nil
        }
        return record
    }

    package static func readPersisted(from overrideURL: URL? = nil) -> LiveEndpointRecord? {
        loadRecord(from: overrideURL ?? defaultFileURL)
    }

    package static func readOwnedRecord(
        pid: Int,
        serverStartTime: ProcessStartTime,
        from overrideURL: URL? = nil
    ) -> LiveEndpointRecord? {
        let fileURL = overrideURL ?? defaultFileURL
        guard let record = loadRecord(from: fileURL),
              ownsRecord(
                record,
                pid: pid,
                serverStartTime: serverStartTime
              )
        else {
            return nil
        }
        return record
    }

    package static func remove(at overrideURL: URL? = nil) {
        try? FileManager.default.removeItem(at: overrideURL ?? defaultFileURL)
    }

    package static func removeIfOwned(
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
        try? FileManager.default.removeItem(at: fileURL)
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

    package static func isMatchingExecutable(_ pid: Int, expectedName: String?) -> Bool {
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

    private static func isLiveRecord(_ record: LiveEndpointRecord) -> Bool {
        guard isProcessAlive(pid_t(record.pid)) else {
            return false
        }
        if processStartTime(of: pid_t(record.pid)) != record.serverStartTime {
            return false
        }
        return isMatchingExecutable(record.pid, expectedName: record.executableName)
    }

    private static func loadRecord(from fileURL: URL) -> LiveEndpointRecord? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? makeDecoder().decode(LiveEndpointRecord.self, from: data)
    }

    private static func currentExecutableName() -> String? {
        ProcessInfo.processInfo.arguments.first.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    private static func ownsRecord(
        _ record: LiveEndpointRecord,
        pid: Int,
        serverStartTime: ProcessStartTime
    ) -> Bool {
        record.pid == pid && record.serverStartTime == serverStartTime
    }
}

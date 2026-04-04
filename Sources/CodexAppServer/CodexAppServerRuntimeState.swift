import Foundation
import ReviewCore

package struct CodexAppServerRuntimeState: Sendable, Equatable {
    package var pid: Int
    package var startTime: ProcessStartTime
    package var processGroupLeaderPID: Int
    package var processGroupLeaderStartTime: ProcessStartTime

    package init(
        pid: Int,
        startTime: ProcessStartTime,
        processGroupLeaderPID: Int,
        processGroupLeaderStartTime: ProcessStartTime
    ) {
        self.pid = pid
        self.startTime = startTime
        self.processGroupLeaderPID = processGroupLeaderPID
        self.processGroupLeaderStartTime = processGroupLeaderStartTime
    }
}

package struct ReviewRuntimeStateRecord: Codable, Sendable, Equatable {
    package var serverPID: Int
    package var serverStartTime: ProcessStartTime
    package var appServerPID: Int
    package var appServerStartTime: ProcessStartTime
    package var appServerProcessGroupLeaderPID: Int
    package var appServerProcessGroupLeaderStartTime: ProcessStartTime
    package var updatedAt: Date

    package init(
        serverPID: Int,
        serverStartTime: ProcessStartTime,
        appServerPID: Int,
        appServerStartTime: ProcessStartTime,
        appServerProcessGroupLeaderPID: Int,
        appServerProcessGroupLeaderStartTime: ProcessStartTime,
        updatedAt: Date
    ) {
        self.serverPID = serverPID
        self.serverStartTime = serverStartTime
        self.appServerPID = appServerPID
        self.appServerStartTime = appServerStartTime
        self.appServerProcessGroupLeaderPID = appServerProcessGroupLeaderPID
        self.appServerProcessGroupLeaderStartTime = appServerProcessGroupLeaderStartTime
        self.updatedAt = updatedAt
    }
}

package enum ReviewRuntimeStateStore {
    package static var defaultFileURL: URL {
        ReviewHomePaths.runtimeStateFileURL()
    }

    package static func write(_ record: ReviewRuntimeStateRecord, to overrideURL: URL? = nil) throws {
        let fileURL = overrideURL ?? defaultFileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeEncoder().encode(record).write(to: fileURL, options: [.atomic])
    }

    package static func read(from overrideURL: URL? = nil) -> ReviewRuntimeStateRecord? {
        let fileURL = overrideURL ?? defaultFileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? makeDecoder().decode(ReviewRuntimeStateRecord.self, from: data)
    }

    package static func remove(at overrideURL: URL? = nil) {
        try? FileManager.default.removeItem(at: overrideURL ?? defaultFileURL)
    }

    package static func removeIfOwned(
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
        try? FileManager.default.removeItem(at: fileURL)
    }
}

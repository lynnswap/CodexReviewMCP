import Foundation
import Testing
@testable import ReviewCore

@Suite
struct ReviewDiscoveryTests {
    @Test func discoveryDefaultFileURLUsesReviewMCPHome() {
        #expect(ReviewDiscovery.defaultFileURL.path.hasSuffix("/.codex_review/review_mcp_endpoint.json"))
    }

    @Test func runtimeStateFileURLUsesReviewMCPHome() {
        #expect(ReviewRuntimeStateStore.defaultFileURL.path.hasSuffix("/.codex_review/review_mcp_runtime_state.json"))
    }

    @Test func discoveryReadsMatchingLiveRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            serverStartTime: try #require(processStartTime(of: pid_t(ProcessInfo.processInfo.processIdentifier))),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(record, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loaded = try #require(ReviewDiscovery.read(from: tempURL))
        #expect(loaded.pid == record.pid)
        #expect(loaded.url == record.url)
    }

    @Test func discoverySkipsDeadProcessRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(Int32.max),
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        try ReviewDiscovery.write(record, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(ReviewDiscovery.read(from: tempURL) == nil)
    }

    @Test func discoveryReadPersistedReturnsStaleRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(Int32.max),
            serverStartTime: .init(seconds: 1, microseconds: 0),
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        try ReviewDiscovery.write(record, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        #expect(ReviewDiscovery.read(from: tempURL) == nil)
        let persisted = try #require(ReviewDiscovery.readPersisted(from: tempURL))
        #expect(persisted.pid == record.pid)
        #expect(persisted.url == record.url)
        #expect(persisted.serverStartTime == record.serverStartTime)
    }

    @Test func discoveryRemoveIfOwnedDeletesMatchingRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            serverStartTime: try #require(processStartTime(of: pid_t(ProcessInfo.processInfo.processIdentifier))),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(record, to: tempURL)
        ReviewDiscovery.removeIfOwned(
            pid: record.pid,
            url: URL(string: record.url),
            serverStartTime: record.serverStartTime,
            at: tempURL
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
    }

    @Test func discoveryRemoveIfOwnedKeepsMismatchedStartTime() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = LiveEndpointRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            serverStartTime: try #require(processStartTime(of: pid_t(ProcessInfo.processInfo.processIdentifier))),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(record, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        ReviewDiscovery.removeIfOwned(
            pid: record.pid,
            url: URL(string: record.url),
            serverStartTime: .init(seconds: 999, microseconds: 0),
            at: tempURL
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path))
    }

    @Test func splitStandardErrorChunkBuffersTrailingPartialLine() {
        let firstSplit = splitStandardErrorChunk(
            existingFragment: "",
            chunk: "first line\npartial"
        )
        #expect(firstSplit.completeLines == ["first line"])
        #expect(firstSplit.trailingFragment == "partial")

        let secondSplit = splitStandardErrorChunk(
            existingFragment: firstSplit.trailingFragment,
            chunk: " line\nsecond line\n"
        )
        #expect(secondSplit.completeLines == ["partial line", "second line", ""])
        #expect(secondSplit.trailingFragment.isEmpty)
    }
}

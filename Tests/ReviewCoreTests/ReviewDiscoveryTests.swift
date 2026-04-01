import Foundation
import Testing
@testable import ReviewCore

@Suite struct ReviewDiscoveryTests {
    @Test func discoveryDefaultFileURLUsesReviewMCPHome() {
        #expect(ReviewDiscovery.defaultFileURL.path.hasSuffix("/.codex_review/endpoint.json"))
    }

    @Test func discoveryUsesURLComponentsForIPv6AndCustomEndpoint() {
        let record = ReviewDiscovery.makeRecord(
            host: "::1",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            endpointPath: "/custom"
        )

        #expect(record?.url == "http://[::1]:9417/custom")
    }

    @Test func discoveryRejectsMismatchedExecutableName() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: "definitely-not-\(UUID().uuidString)"
        )

        try ReviewDiscovery.write(record, to: tempURL)
        defer { ReviewDiscovery.remove(at: tempURL) }

        let loaded = ReviewDiscovery.read(from: tempURL)
        #expect(loaded == nil)
    }

    @Test func discoveryReadsMatchingNonLoopbackRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://192.168.0.10:9417/mcp",
            host: "192.168.0.10",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(record, to: tempURL)
        defer { ReviewDiscovery.remove(at: tempURL) }

        let loaded = ReviewDiscovery.read(from: tempURL)
        #expect(loaded?.host == "192.168.0.10")
    }

    @Test func discoveryFallsBackToLegacyCandidateWhenPrimaryRecordIsInvalid() throws {
        let primaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let invalidPrimary = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier) + 1,
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )
        let legacyRecord = ReviewDiscoveryRecord(
            url: "http://192.168.0.10:9417/mcp",
            host: "192.168.0.10",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(invalidPrimary, to: primaryURL)
        try ReviewDiscovery.write(legacyRecord, to: legacyURL)
        defer {
            ReviewDiscovery.remove(at: primaryURL)
            ReviewDiscovery.remove(at: legacyURL)
        }

        let loaded = ReviewDiscovery.read(fromCandidateURLs: [primaryURL, legacyURL])
        #expect(loaded?.host == "192.168.0.10")
    }

    @Test func discoveryRemoveIfOwnedKeepsForeignRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier) + 1,
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        try ReviewDiscovery.write(record, to: tempURL)
        ReviewDiscovery.removeIfOwned(
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            url: URL(string: record.url),
            at: tempURL
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path))
        ReviewDiscovery.remove(at: tempURL)
    }

    @Test func discoveryRemoveIfOwnedDeletesMatchingRecord() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        try ReviewDiscovery.write(record, to: tempURL)
        ReviewDiscovery.removeIfOwned(
            pid: record.pid,
            url: URL(string: record.url),
            at: tempURL
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path) == false)
    }

    @Test func discoveryRemoveIfOwnedKeepsMismatchedURLForSamePID() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: "codex-review-mcp-server"
        )

        try ReviewDiscovery.write(record, to: tempURL)
        ReviewDiscovery.removeIfOwned(
            pid: record.pid,
            url: URL(string: "http://localhost:9999/mcp"),
            at: tempURL
        )

        #expect(FileManager.default.fileExists(atPath: tempURL.path))
        ReviewDiscovery.remove(at: tempURL)
    }

    @Test func discoveryRemoveDeletesLegacyAndPrimaryLocationsTogether() throws {
        let primaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(record, to: primaryURL)
        try ReviewDiscovery.write(record, to: legacyURL)

        ReviewDiscovery.remove(atFileURLs: [primaryURL, legacyURL])

        #expect(FileManager.default.fileExists(atPath: primaryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        ReviewDiscovery.remove(at: primaryURL)
        ReviewDiscovery.remove(at: legacyURL)
    }

    @Test func discoveryRemoveIfOwnedDeletesLegacyAndPrimaryLocationsTogether() throws {
        let primaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let record = ReviewDiscoveryRecord(
            url: "http://localhost:9417/mcp",
            host: "localhost",
            port: 9417,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date(),
            executableName: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        )

        try ReviewDiscovery.write(record, to: primaryURL)
        try ReviewDiscovery.write(record, to: legacyURL)

        ReviewDiscovery.removeIfOwned(pid: record.pid, url: URL(string: record.url), atFileURLs: [primaryURL, legacyURL])

        #expect(FileManager.default.fileExists(atPath: primaryURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        ReviewDiscovery.remove(at: primaryURL)
        ReviewDiscovery.remove(at: legacyURL)
    }
}

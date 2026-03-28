import Foundation
import Testing
@testable import ReviewCore

@Suite struct ReviewEventParserTests {
    @Test func reviewEventParserDetectsSuccessfulTurn() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"Looks good"}}
        {"type":"turn.completed"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var snapshot = ReviewEventSnapshot()
        _ = snapshot.refresh(fileURL: fileURL)

        #expect(snapshot.threadID == "thread-1")
        #expect(snapshot.lastAgentMessage == "Looks good")
        #expect(snapshot.terminalState == .success)
    }

    @Test func reviewEventParserDetectsFailedTurn() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-2"}
        {"type":"turn.started"}
        {"type":"error","error":{"message":"boom"}}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var snapshot = ReviewEventSnapshot()
        _ = snapshot.refresh(fileURL: fileURL)

        #expect(snapshot.threadID == "thread-2")
        #expect(snapshot.errorMessage == "boom")
        #expect(snapshot.terminalState == .failure)
    }

    @Test func reviewEventParserProcessesAppendedEventsIncrementally() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-3"}
        {"type":"turn.started"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var snapshot = ReviewEventSnapshot()
        _ = snapshot.refresh(fileURL: fileURL)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        handle.write(Data("""
        {"type":"item.completed","item":{"type":"agent_message","text":"Recovered"}}
        {"type":"turn.completed"}
        """.utf8))

        _ = snapshot.refresh(fileURL: fileURL)

        #expect(snapshot.threadID == "thread-3")
        #expect(snapshot.lastAgentMessage == "Recovered")
        #expect(snapshot.terminalState == .success)
    }

    @Test func reviewEventParserResetsTerminalStateForNewTurn() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-4"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"Looks good"}}
        {"type":"turn.completed"}
        {"type":"turn.started"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var snapshot = ReviewEventSnapshot()
        _ = snapshot.refresh(fileURL: fileURL)

        #expect(snapshot.threadID == "thread-4")
        #expect(snapshot.terminalState == .none)
        #expect(snapshot.lastAgentMessage == "Looks good")
    }

    @Test func reviewEventParserPreservesActiveTurnMessageWhileNonTerminal() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-5"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"Done"}}
        {"type":"turn.completed"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"Still working"}}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var snapshot = ReviewEventSnapshot()
        _ = snapshot.refresh(fileURL: fileURL)

        #expect(snapshot.terminalState == .none)
        #expect(snapshot.lastAgentMessage == "Still working")
    }

    @Test func reviewEventParserClearsPreviousTurnErrorWhenNewTurnStarts() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-6"}
        {"type":"turn.started"}
        {"type":"error","error":{"message":"boom"}}
        {"type":"turn.started"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var snapshot = ReviewEventSnapshot()
        _ = snapshot.refresh(fileURL: fileURL)

        #expect(snapshot.terminalState == .none)
        #expect(snapshot.errorMessage.isEmpty)
    }
}

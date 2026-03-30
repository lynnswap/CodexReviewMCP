import Foundation
import Testing
@testable import ReviewCore

@Suite
struct ReviewEventParserTests {
    @Test func reviewEventParserDetectsSuccessfulTurn() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"Looks good"}}
        {"type":"turn.completed"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var parser = ReviewEventParser()
        let events = parser.refresh(fileURL: fileURL)

        #expect(parser.threadID == "thread-1")
        #expect(parser.lastAgentMessage == "Looks good")
        #expect(parser.terminalState == .success)
        #expect(events.contains { event in
            if case .threadStarted("thread-1") = event { return true }
            return false
        })
    }

    @Test func reviewEventParserDetectsFailedTurn() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-2"}
        {"type":"turn.started"}
        {"type":"error","error":{"message":"boom"}}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var parser = ReviewEventParser()
        let events = parser.refresh(fileURL: fileURL)

        #expect(parser.threadID == "thread-2")
        #expect(parser.errorMessage == "boom")
        #expect(parser.terminalState == .failure)
        #expect(events.contains { event in
            if case .failed("boom") = event { return true }
            return false
        })
    }

    @Test func reviewEventParserProcessesAppendedEventsIncrementally() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-3"}
        {"type":"turn.started"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var parser = ReviewEventParser()
        _ = parser.refresh(fileURL: fileURL)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data("""
        {"type":"item.completed","item":{"type":"agent_message","text":"Recovered"}}
        {"type":"turn.completed"}
        """.utf8))

        let events = parser.refresh(fileURL: fileURL)

        #expect(parser.threadID == "thread-3")
        #expect(parser.lastAgentMessage == "Recovered")
        #expect(parser.terminalState == .success)
        #expect(events.contains { event in
            if case .agentMessage("Recovered") = event { return true }
            return false
        })
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

        var parser = ReviewEventParser()
        _ = parser.refresh(fileURL: fileURL)

        #expect(parser.threadID == "thread-4")
        #expect(parser.terminalState == .none)
        #expect(parser.lastAgentMessage == "Looks good")
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

        var parser = ReviewEventParser()
        _ = parser.refresh(fileURL: fileURL)

        #expect(parser.terminalState == .none)
        #expect(parser.lastAgentMessage == "Still working")
    }

    @Test func reviewEventParserClearsPreviousTurnErrorWhenNewTurnStarts() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try """
        {"type":"thread.started","thread_id":"thread-6"}
        {"type":"turn.started"}
        {"type":"error","error":{"message":"boom"}}
        {"type":"turn.started"}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var parser = ReviewEventParser()
        _ = parser.refresh(fileURL: fileURL)

        #expect(parser.terminalState == .none)
        #expect(parser.errorMessage.isEmpty)
    }
}

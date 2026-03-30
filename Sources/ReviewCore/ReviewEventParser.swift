import Foundation
import ReviewJobs

package enum ReviewTerminalState: String, Sendable {
    case none
    case success
    case failure
}

package struct ReviewEventParser: Sendable {
    package private(set) var threadID: String?
    package private(set) var lastAgentMessage: String?
    package private(set) var errorMessage = ""
    package private(set) var terminalState: ReviewTerminalState = .none

    private var sizeBytes = -1
    private var readOffset = 0
    private var pendingLine = Data()
    private var currentTurn = TurnAccumulator()
    private var latestCompletedTurn: TurnAnalysis?
    private var latestTerminalTurn: TurnAnalysis?

    package init() {}

    package mutating func refresh(fileURL: URL, force: Bool = false) -> [ReviewProcessEvent] {
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if force || currentSize < sizeBytes {
            reset()
        } else if currentSize == sizeBytes {
            return []
        }

        let appendedData = readAppendedData(fileURL: fileURL, fromOffset: readOffset) ?? Data()
        sizeBytes = currentSize
        readOffset = currentSize
        pendingLine.append(appendedData)

        var events: [ReviewProcessEvent] = []
        processPendingLines(into: &events)
        publishState()
        return events
    }

    private mutating func reset() {
        threadID = nil
        lastAgentMessage = nil
        errorMessage = ""
        terminalState = .none
        sizeBytes = -1
        readOffset = 0
        pendingLine.removeAll(keepingCapacity: false)
        currentTurn = TurnAccumulator()
        latestCompletedTurn = nil
        latestTerminalTurn = nil
    }

    private mutating func processPendingLines(into events: inout [ReviewProcessEvent]) {
        while let newlineIndex = pendingLine.firstIndex(of: 0x0A) {
            let lineData = Data(pendingLine[..<newlineIndex])
            pendingLine.removeSubrange(...newlineIndex)
            processLineData(lineData, into: &events)
        }

        if let entry = parseEntry(from: pendingLine) {
            process(entry: entry, rawLine: String(decoding: pendingLine, as: UTF8.self), into: &events)
            pendingLine.removeAll(keepingCapacity: true)
        }
    }

    private mutating func processLineData(_ data: Data, into events: inout [ReviewProcessEvent]) {
        guard data.isEmpty == false, let entry = parseEntry(from: data) else {
            return
        }
        process(entry: entry, rawLine: String(decoding: data, as: UTF8.self), into: &events)
    }

    private mutating func process(
        entry: [String: Any],
        rawLine: String,
        into events: inout [ReviewProcessEvent]
    ) {
        let trimmedRawLine = trimmedLine(rawLine)
        appendRawLine(trimmedRawLine, into: &events)

        if threadID == nil,
           (entry["type"] as? String) == "thread.started",
           let value = entry["thread_id"] as? String
        {
            threadID = value
            events.append(.threadStarted(value))
        }

        if (entry["type"] as? String) == "turn.started", currentTurn.hasEntries {
            finalizeCurrentTurn()
        }

        currentTurn.append(entry, rawLine: trimmedRawLine, into: &events)
    }

    private mutating func finalizeCurrentTurn() {
        guard currentTurn.hasEntries else {
            return
        }
        let analysis = currentTurn.analysis()
        latestCompletedTurn = analysis
        if analysis.terminalState != .none {
            latestTerminalTurn = analysis
        }
        currentTurn = TurnAccumulator()
    }

    private mutating func publishState() {
        lastAgentMessage = nil
        errorMessage = ""
        terminalState = .none

        let currentAnalysis = currentTurn.hasEntries ? currentTurn.analysis() : nil
        if let currentAnalysis, currentAnalysis.terminalState != .none {
            latestTerminalTurn = currentAnalysis
        }

        if let currentAnalysis {
            terminalState = currentAnalysis.terminalState
            lastAgentMessage = currentAnalysis.lastAgentMessage
            errorMessage = currentAnalysis.errorMessage
            if terminalState == .none, let terminalAnalysis = latestTerminalTurn, lastAgentMessage == nil {
                lastAgentMessage = terminalAnalysis.lastAgentMessage
            }
            return
        }

        guard let latestAnalysis = latestCompletedTurn else {
            return
        }
        terminalState = latestAnalysis.terminalState
        lastAgentMessage = latestAnalysis.lastAgentMessage
        errorMessage = latestAnalysis.errorMessage
    }

    private mutating func appendRawLine(_ line: String, into events: inout [ReviewProcessEvent]) {
        guard line.isEmpty == false else {
            return
        }
        events.append(.rawLine(line))
    }
}

private struct TurnAccumulator: Sendable {
    var hasEntries = false
    var lastAgentMessage: String?
    var lastTurnCompletedIndex: Int?
    var lastErrorIndex: Int?
    var fallbackErrorMessage = ""
    var lastTurnFailedError = ""
    private var entryIndex = 0

    mutating func append(
        _ entry: [String: Any],
        rawLine: String,
        into events: inout [ReviewProcessEvent]
    ) {
        hasEntries = true

        let emitted: Bool
        switch entry["type"] as? String {
        case "thread.started":
            emitted = appendLog(kind: .event, text: rawLine, into: &events)
        case "turn.started":
            emitted = appendLog(kind: .event, text: rawLine, into: &events)
        case "item.started":
            emitted = appendStartedItem(entry["item"], into: &events)
        case "item.updated":
            emitted = appendUpdatedItem(entry["item"], into: &events)
        case "item.completed":
            emitted = appendCompletedItem(entry["item"], into: &events)
        case "turn.completed":
            lastTurnCompletedIndex = entryIndex
            emitted = appendLog(kind: .event, text: rawLine, into: &events)
        case "turn.failed":
            lastTurnFailedError = parseErrorMessage(entry["error"])
            if lastTurnFailedError.isEmpty == false {
                events.append(.failed(lastTurnFailedError))
                emitted = appendLog(kind: .error, text: lastTurnFailedError, into: &events)
            } else {
                emitted = appendLog(kind: .event, text: rawLine, into: &events)
            }
        case "error":
            lastErrorIndex = entryIndex
            let message = parseErrorMessage(entry)
            if message.isEmpty == false {
                fallbackErrorMessage = message
                events.append(.failed(message))
                emitted = appendLog(kind: .error, text: message, into: &events)
            } else {
                emitted = appendLog(kind: .event, text: rawLine, into: &events)
            }
        default:
            emitted = false
        }

        if emitted == false {
            _ = appendLog(kind: .event, text: rawLine, into: &events)
        }

        entryIndex += 1
    }

    func analysis() -> TurnAnalysis {
        if lastTurnFailedError.isEmpty == false {
            return .init(
                lastAgentMessage: lastAgentMessage,
                errorMessage: lastTurnFailedError,
                terminalState: .failure
            )
        }
        if let lastTurnCompletedIndex,
           lastAgentMessage?.isEmpty == false,
           (lastErrorIndex.map { $0 < lastTurnCompletedIndex } ?? true)
        {
            return .init(
                lastAgentMessage: lastAgentMessage,
                errorMessage: "",
                terminalState: .success
            )
        }
        if lastErrorIndex != nil {
            return .init(
                lastAgentMessage: lastAgentMessage,
                errorMessage: fallbackErrorMessage,
                terminalState: .failure
            )
        }
        return .init(
            lastAgentMessage: lastAgentMessage,
            errorMessage: "",
            terminalState: .none
        )
    }

    private mutating func appendStartedItem(_ rawItem: Any?, into events: inout [ReviewProcessEvent]) -> Bool {
        guard let item = rawItem as? [String: Any],
              let type = item["type"] as? String
        else {
            return false
        }

        switch type {
        case "command_execution":
            let command = trimmedLine(item["command"] as? String)
            return appendLog(kind: .command, text: command.isEmpty ? "" : "$ \(command)", into: &events)
        case "todo_list":
            return appendLog(kind: .todoList, text: formattedTodoList(from: item) ?? "", into: &events)
        default:
            return false
        }
    }

    private mutating func appendUpdatedItem(_ rawItem: Any?, into events: inout [ReviewProcessEvent]) -> Bool {
        guard let item = rawItem as? [String: Any],
              (item["type"] as? String) == "todo_list"
        else {
            return false
        }
        return appendLog(kind: .todoList, text: formattedTodoList(from: item) ?? "", into: &events)
    }

    private mutating func appendCompletedItem(_ rawItem: Any?, into events: inout [ReviewProcessEvent]) -> Bool {
        guard let item = rawItem as? [String: Any],
              let type = item["type"] as? String
        else {
            return false
        }

        switch type {
        case "agent_message":
            let text = trimmedLine(item["text"] as? String)
            guard appendLog(kind: .agentMessage, text: text, into: &events) else {
                return false
            }
            lastAgentMessage = text
            events.append(.agentMessage(text))
            return true
        case "reasoning":
            let text = trimmedLine(item["text"] as? String)
            return appendLog(kind: .reasoning, text: text, into: &events)
        case "command_execution":
            let output = trimmedLine(item["aggregated_output"] as? String)
            return appendLog(kind: .commandOutput, text: output, into: &events)
        case "todo_list":
            return appendLog(kind: .todoList, text: formattedTodoList(from: item) ?? "", into: &events)
        case "error":
            let message = trimmedLine(item["message"] as? String)
            guard appendLog(kind: .error, text: message, into: &events) else {
                return false
            }
            events.append(.failed(message))
            return true
        default:
            return false
        }
    }

    private func formattedTodoList(from item: [String: Any]) -> String? {
        guard let items = item["items"] as? [[String: Any]], items.isEmpty == false else {
            return nil
        }
        let lines = items.compactMap { item -> String? in
            let text = trimmedLine(item["text"] as? String)
            guard text.isEmpty == false else {
                return nil
            }
            let completed = (item["completed"] as? Bool) == true
            return "\(completed ? "[x]" : "[ ]") \(text)"
        }
        guard lines.isEmpty == false else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    private func appendLog(
        kind: ReviewLogEntry.Kind,
        text: String,
        into events: inout [ReviewProcessEvent]
    ) -> Bool {
        guard text.isEmpty == false else {
            return false
        }
        events.append(.logEntry(.init(kind: kind, text: text)))
        return true
    }
}

private struct TurnAnalysis: Sendable {
    var lastAgentMessage: String?
    var errorMessage: String
    var terminalState: ReviewTerminalState
}

private func readAppendedData(fileURL: URL, fromOffset: Int) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
        return nil
    }
    defer {
        try? handle.close()
    }
    try? handle.seek(toOffset: UInt64(max(fromOffset, 0)))
    return try? handle.readToEnd() ?? Data()
}

private func parseEntry(from data: Data) -> [String: Any]? {
    guard data.isEmpty == false,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object
}

private func parseErrorMessage(_ raw: Any?) -> String {
    guard let raw else {
        return ""
    }
    if let text = raw as? String {
        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data)
        {
            return parseErrorMessage(parsed)
        }
        return text
    }
    guard let dictionary = raw as? [String: Any] else {
        return ""
    }
    if let error = dictionary["error"] as? [String: Any] {
        if let message = error["message"] as? String {
            return message
        }
        if let code = error["code"] as? String {
            return code
        }
    }
    if let error = dictionary["error"] as? String {
        return error
    }
    if let message = dictionary["message"] as? String {
        return message
    }
    if let code = dictionary["code"] as? String {
        return code
    }
    return ""
}

private func trimmedLine(_ text: String?) -> String {
    (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

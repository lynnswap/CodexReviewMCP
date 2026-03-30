import Foundation

package enum ReviewTerminalState: String, Sendable {
    case none
    case success
    case failure
}

package struct ReviewEventSnapshot: Sendable {
    package var sizeBytes = -1
    package var threadID: String?
    package var lastAgentMessage = ""
    package var reviewLogText = ""
    package var reasoningLogText = ""
    package var rawLogText = ""
    package var errorMessage = ""
    package var terminalState: ReviewTerminalState = .none

    private var readOffset = 0
    private var pendingLine = Data()
    private var currentTurn = TurnAccumulator()
    private var latestCompletedTurn: TurnAnalysis?
    private var latestTerminalTurn: TurnAnalysis?

    package init() {}

    package mutating func refresh(fileURL: URL, force: Bool = false) -> Bool {
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if force || currentSize < sizeBytes {
            reset()
        } else if currentSize == sizeBytes {
            return false
        }

        let appendedData = readAppendedData(fileURL: fileURL, fromOffset: readOffset) ?? Data()
        sizeBytes = currentSize
        readOffset = currentSize
        pendingLine.append(appendedData)
        processPendingLines()
        publishState()
        return true
    }

    private mutating func reset() {
        sizeBytes = -1
        threadID = nil
        lastAgentMessage = ""
        reviewLogText = ""
        reasoningLogText = ""
        rawLogText = ""
        errorMessage = ""
        terminalState = .none
        readOffset = 0
        pendingLine.removeAll(keepingCapacity: false)
        currentTurn = TurnAccumulator()
        latestCompletedTurn = nil
        latestTerminalTurn = nil
    }

    private mutating func processPendingLines() {
        while let newlineIndex = pendingLine.firstIndex(of: 0x0A) {
            let lineData = Data(pendingLine[..<newlineIndex])
            pendingLine.removeSubrange(...newlineIndex)
            processLineData(lineData)
        }

        if let entry = parseEntry(from: pendingLine) {
            process(entry: entry, rawLine: String(decoding: pendingLine, as: UTF8.self))
            pendingLine.removeAll(keepingCapacity: true)
        }
    }

    private mutating func processLineData(_ data: Data) {
        guard data.isEmpty == false, let entry = parseEntry(from: data) else {
            return
        }
        process(entry: entry, rawLine: String(decoding: data, as: UTF8.self))
    }

    private mutating func process(entry: [String: Any], rawLine: String) {
        if threadID == nil,
           (entry["type"] as? String) == "thread.started",
           let value = entry["thread_id"] as? String
        {
            threadID = value
        }

        appendRawLine(rawLine)

        if (entry["type"] as? String) == "turn.started", currentTurn.hasEntries {
            finalizeCurrentTurn()
        }

        currentTurn.append(entry)
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
        lastAgentMessage = ""
        reviewLogText = ""
        reasoningLogText = ""
        errorMessage = ""
        terminalState = .none

        let currentAnalysis = currentTurn.hasEntries ? currentTurn.analysis() : nil
        if let currentAnalysis, currentAnalysis.terminalState != .none {
            latestTerminalTurn = currentAnalysis
        }

        if let currentAnalysis {
            terminalState = currentAnalysis.terminalState
            lastAgentMessage = currentAnalysis.lastAgentMessage
            reviewLogText = currentAnalysis.reviewLogText
            reasoningLogText = currentAnalysis.reasoningLogText
            errorMessage = currentAnalysis.errorMessage
            if terminalState == .none, let terminalAnalysis = latestTerminalTurn {
                if lastAgentMessage.isEmpty {
                    lastAgentMessage = terminalAnalysis.lastAgentMessage
                }
                if reviewLogText.isEmpty {
                    reviewLogText = terminalAnalysis.reviewLogText
                }
                if reasoningLogText.isEmpty {
                    reasoningLogText = terminalAnalysis.reasoningLogText
                }
            }
            return
        }

        guard let latestAnalysis = latestCompletedTurn else {
            return
        }
        terminalState = latestAnalysis.terminalState
        lastAgentMessage = latestAnalysis.lastAgentMessage
        reviewLogText = latestAnalysis.reviewLogText
        reasoningLogText = latestAnalysis.reasoningLogText
        errorMessage = latestAnalysis.errorMessage
    }

    private mutating func appendRawLine(_ line: String) {
        rawLogText = trimmedParserText(appending: line + "\n", to: rawLogText)
    }
}

private struct TurnAccumulator: Sendable {
    var hasEntries = false
    var lastAgentMessage = ""
    var reviewLogText = ""
    var reasoningLogText = ""
    var lastTurnCompletedIndex: Int?
    var lastErrorIndex: Int?
    var fallbackErrorMessage = ""
    var lastTurnFailedError = ""
    private var entryIndex = 0

    mutating func append(_ entry: [String: Any]) {
        hasEntries = true
        switch entry["type"] as? String {
        case "item.started":
            appendStartedItem(entry["item"])
        case "item.updated":
            appendUpdatedItem(entry["item"])
        case "item.completed":
            appendCompletedItem(entry["item"])
        case "turn.completed":
            lastTurnCompletedIndex = entryIndex
        case "turn.failed":
            lastTurnFailedError = parseErrorMessage(entry["error"])
            if lastTurnFailedError.isEmpty == false {
                appendReviewLine(lastTurnFailedError)
            }
        case "error":
            lastErrorIndex = entryIndex
            let message = parseErrorMessage(entry)
            if message.isEmpty == false {
                fallbackErrorMessage = message
                appendReviewLine(message)
            }
        default:
            break
        }
        entryIndex += 1
    }

    func analysis() -> TurnAnalysis {
        if lastTurnFailedError.isEmpty == false {
            return TurnAnalysis(
                lastAgentMessage: lastAgentMessage,
                reviewLogText: reviewLogText,
                reasoningLogText: reasoningLogText,
                errorMessage: lastTurnFailedError,
                terminalState: .failure
            )
        }
        if let lastTurnCompletedIndex,
           lastAgentMessage.isEmpty == false,
           lastErrorIndex == nil || lastErrorIndex! < lastTurnCompletedIndex
        {
            return TurnAnalysis(
                lastAgentMessage: lastAgentMessage,
                reviewLogText: reviewLogText,
                reasoningLogText: reasoningLogText,
                errorMessage: "",
                terminalState: .success
            )
        }
        if lastErrorIndex != nil {
            return TurnAnalysis(
                lastAgentMessage: lastAgentMessage,
                reviewLogText: reviewLogText,
                reasoningLogText: reasoningLogText,
                errorMessage: fallbackErrorMessage,
                terminalState: .failure
            )
        }
        return TurnAnalysis(
            lastAgentMessage: lastAgentMessage,
            reviewLogText: reviewLogText,
            reasoningLogText: reasoningLogText,
            errorMessage: "",
            terminalState: .none
        )
    }

    private mutating func appendStartedItem(_ rawItem: Any?) {
        guard let item = rawItem as? [String: Any],
              let type = item["type"] as? String
        else {
            return
        }

        switch type {
        case "command_execution":
            let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if command.isEmpty == false {
                appendReviewLine("$ \(command)")
            }
        case "todo_list":
            if let todoList = formattedTodoList(from: item) {
                appendReviewLine(todoList)
            }
        default:
            break
        }
    }

    private mutating func appendUpdatedItem(_ rawItem: Any?) {
        guard let item = rawItem as? [String: Any],
              let type = item["type"] as? String
        else {
            return
        }

        switch type {
        case "todo_list":
            if let todoList = formattedTodoList(from: item) {
                appendReviewLine(todoList)
            }
        default:
            break
        }
    }

    private mutating func appendCompletedItem(_ rawItem: Any?) {
        guard let item = rawItem as? [String: Any],
              let type = item["type"] as? String
        else {
            return
        }

        switch type {
        case "agent_message":
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty == false {
                lastAgentMessage = text
                appendReviewLine(text)
            }
        case "reasoning":
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty == false {
                appendReasoningLine(text)
            }
        case "command_execution":
            let output = (item["aggregated_output"] as? String)?.trimmingCharacters(in: .newlines) ?? ""
            if output.isEmpty == false {
                appendReviewLine(output)
            }
        case "todo_list":
            if let todoList = formattedTodoList(from: item) {
                appendReviewLine(todoList)
            }
        case "error":
            let message = (item["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.isEmpty == false {
                appendReviewLine(message)
            }
        default:
            break
        }
    }

    private mutating func appendReviewLine(_ text: String) {
        append(text, to: &reviewLogText)
    }

    private mutating func appendReasoningLine(_ text: String) {
        append(text, to: &reasoningLogText)
    }

    private func formattedTodoList(from item: [String: Any]) -> String? {
        guard let items = item["items"] as? [[String: Any]], items.isEmpty == false else {
            return nil
        }
        let lines = items.compactMap { item -> String? in
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    private func append(_ text: String, to target: inout String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return
        }
        if target.isEmpty == false {
            target.append("\n\n")
        }
        target.append(trimmed)
    }
}

private struct TurnAnalysis: Sendable {
    var lastAgentMessage: String
    var reviewLogText: String
    var reasoningLogText: String
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

private func trimmedParserText(appending line: String, to existing: String) -> String {
    var text = existing
    text.append(line)
    guard text.utf8.count > reviewMonitorLogLimitBytes else {
        return text
    }

    let bytes = Array(text.utf8)
    let start = max(bytes.count - reviewMonitorLogLimitBytes, 0)
    let suffix = Array(bytes[start...])
    let firstNewline = suffix.firstIndex(of: 0x0A).map { suffix.index(after: $0) } ?? suffix.startIndex
    return String(decoding: suffix[firstNewline...], as: UTF8.self)
}

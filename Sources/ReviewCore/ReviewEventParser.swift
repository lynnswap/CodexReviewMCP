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
            process(entry: entry)
            pendingLine.removeAll(keepingCapacity: true)
        }
    }

    private mutating func processLineData(_ data: Data) {
        guard data.isEmpty == false, let entry = parseEntry(from: data) else {
            return
        }
        process(entry: entry)
    }

    private mutating func process(entry: [String: Any]) {
        if threadID == nil,
           (entry["type"] as? String) == "thread.started",
           let value = entry["thread_id"] as? String
        {
            threadID = value
        }

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
            if terminalState == .none, lastAgentMessage.isEmpty, let terminalAnalysis = latestTerminalTurn {
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
}

private struct TurnAccumulator: Sendable {
    var hasEntries = false
    var lastAgentMessage = ""
    var lastTurnCompletedIndex: Int?
    var lastErrorIndex: Int?
    var fallbackErrorMessage = ""
    var lastTurnFailedError = ""
    private var entryIndex = 0

    mutating func append(_ entry: [String: Any]) {
        hasEntries = true
        switch entry["type"] as? String {
        case "item.completed":
            if let item = entry["item"] as? [String: Any],
               (item["type"] as? String) == "agent_message",
               let text = item["text"] as? String
            {
                lastAgentMessage = text
            }
        case "turn.completed":
            lastTurnCompletedIndex = entryIndex
        case "turn.failed":
            lastTurnFailedError = parseErrorMessage(entry["error"])
        case "error":
            lastErrorIndex = entryIndex
            let message = parseErrorMessage(entry)
            if message.isEmpty == false {
                fallbackErrorMessage = message
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
                errorMessage: "",
                terminalState: .success
            )
        }
        if lastErrorIndex != nil {
            return TurnAnalysis(
                lastAgentMessage: lastAgentMessage,
                errorMessage: fallbackErrorMessage,
                terminalState: .failure
            )
        }
        return TurnAnalysis(
            lastAgentMessage: lastAgentMessage,
            errorMessage: "",
            terminalState: .none
        )
    }
}

private struct TurnAnalysis: Sendable {
    var lastAgentMessage: String
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

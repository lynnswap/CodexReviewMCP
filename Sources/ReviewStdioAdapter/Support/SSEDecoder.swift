import Foundation

package struct SSEDecoder {
    private var dataLines: [String] = []
    private var currentEventID: String?
    package private(set) var lastEventID: String?

    package init() {}

    mutating func feed(line: String) -> ReviewStdioSSEEvent? {
        let normalized = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if normalized.isEmpty {
            return flushIfNeeded()
        }
        if normalized.hasPrefix(":") {
            return nil
        }
        if normalized.hasPrefix("id:") {
            var value = normalized.dropFirst(3)
            if value.first == " " {
                value = value.dropFirst()
            }
            currentEventID = String(value)
            return nil
        }
        guard normalized.hasPrefix("data:") else {
            return nil
        }
        var payload = normalized.dropFirst(5)
        if payload.first == " " {
            payload = payload.dropFirst()
        }
        dataLines.append(String(payload))
        return nil
    }

    mutating func flushIfNeeded() -> ReviewStdioSSEEvent? {
        guard dataLines.isEmpty == false else {
            return nil
        }
        let payload = dataLines.joined(separator: "\n")
        let event = ReviewStdioSSEEvent(id: currentEventID, payload: Data(payload.utf8))
        lastEventID = currentEventID ?? lastEventID
        currentEventID = nil
        dataLines.removeAll(keepingCapacity: true)
        return event
    }
}

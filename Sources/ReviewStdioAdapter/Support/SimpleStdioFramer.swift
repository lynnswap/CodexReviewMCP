import Foundation

package struct SimpleStdioFramer {
    private var buffer = Data()

    package init() {}

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let message = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            let trimmed = Data(message).trimmingWhitespace()
            if trimmed.isEmpty == false {
                messages.append(trimmed)
            }
        }
        return messages
    }
}

private extension Data {
    func trimmingWhitespace() -> Data {
        guard let text = String(data: self, encoding: .utf8) else {
            return self
        }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}

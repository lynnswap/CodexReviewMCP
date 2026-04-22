import Foundation

final class StdioWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        handle.write(payload)
    }
}

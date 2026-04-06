import Foundation

public actor OneShotGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    public func open() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    public func reset() {
        isOpen = false
    }

    public func wait() async {
        if isOpen {
            return
        }

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    public func isOpenForTesting() -> Bool {
        isOpen
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume()
    }
}

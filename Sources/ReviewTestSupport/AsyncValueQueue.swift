import Foundation

public actor AsyncValueQueue<Value: Sendable> {
    private var buffered: [Value] = []
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    public init() {}

    public func push(_ value: Value) {
        if let id = waiters.keys.first,
           let continuation = waiters.removeValue(forKey: id)
        {
            continuation.resume(returning: value)
            return
        }
        buffered.append(value)
    }

    public func next() async -> Value? {
        if buffered.isEmpty == false {
            return buffered.removeFirst()
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    public func drain() -> [Value] {
        defer { buffered.removeAll(keepingCapacity: false) }
        return buffered
    }

    public func count() -> Int {
        buffered.count
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: nil)
    }
}

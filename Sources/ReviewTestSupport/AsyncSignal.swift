import Foundation

public actor AsyncSignal {
    private var countStorage = 0
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func signal() {
        countStorage += 1

        let readyTargets = waiters.keys.filter { $0 <= countStorage }.sorted()
        for target in readyTargets {
            let continuations = waiters.removeValue(forKey: target) ?? []
            for continuation in continuations {
                continuation.resume()
            }
        }
    }

    public func count() -> Int {
        countStorage
    }

    public func wait(untilCount target: Int = 1) async {
        if countStorage >= target {
            return
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if countStorage >= target {
                    continuation.resume()
                    return
                }
                waiters[target, default: []].append(continuation)
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(target: target)
            }
        }
    }

    private func cancelWaiter(target: Int) {
        guard var continuations = waiters[target], continuations.isEmpty == false else {
            return
        }
        let continuation = continuations.removeFirst()
        if continuations.isEmpty {
            waiters[target] = nil
        } else {
            waiters[target] = continuations
        }
        continuation.resume()
    }
}

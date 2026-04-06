import Foundation

public actor AsyncSignal {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var countStorage = 0
    private var waiters: [Int: [Waiter]] = [:]

    public init() {}

    public func signal() {
        countStorage += 1

        let readyTargets = waiters.keys.filter { $0 <= countStorage }.sorted()
        for target in readyTargets {
            let waitersForTarget = waiters.removeValue(forKey: target) ?? []
            for waiter in waitersForTarget {
                waiter.continuation.resume()
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

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if countStorage >= target {
                    continuation.resume()
                    return
                }
                waiters[target, default: []].append(
                    .init(id: id, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id, target: target)
            }
        }
    }

    package func waiterCount(forTarget target: Int) -> Int {
        waiters[target]?.count ?? 0
    }

    private func cancelWaiter(id: UUID, target: Int) {
        guard var waitersForTarget = waiters[target],
              let index = waitersForTarget.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = waitersForTarget.remove(at: index)
        if waitersForTarget.isEmpty {
            waiters[target] = nil
        } else {
            waiters[target] = waitersForTarget
        }
        waiter.continuation.resume()
    }
}

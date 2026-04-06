import Foundation
import Testing
import ReviewTestSupport

@Suite(.serialized)
struct AsyncSignalTests {
    @Test func cancellingOneWaiterDoesNotResumeAnotherWaitingForSameCount() async {
        let signal = AsyncSignal()
        let completionSignal = AsyncSignal()

        let cancelledTask = Task {
            await signal.wait(untilCount: 1)
        }
        let survivingTask = Task {
            await signal.wait(untilCount: 1)
            await completionSignal.signal()
        }

        await waitForWaiterCount(signal, target: 1, expectedCount: 2)

        cancelledTask.cancel()
        _ = await cancelledTask.value

        await waitForWaiterCount(signal, target: 1, expectedCount: 1)
        #expect(await completionSignal.count() == 0)

        await signal.signal()
        await completionSignal.wait()
        _ = await survivingTask.value
    }
}

private func waitForWaiterCount(
    _ signal: AsyncSignal,
    target: Int,
    expectedCount: Int,
    maxYields: Int = 1_000
) async {
    for _ in 0..<maxYields {
        if await signal.waiterCount(forTarget: target) == expectedCount {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for AsyncSignal waiter count \(expectedCount) on target \(target).")
}

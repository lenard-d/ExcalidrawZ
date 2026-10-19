import Foundation
import XCTest

enum SaveTestWaitError: Error {
    case timedOut
}

/// Uses an unstructured observer so timeout does not join an uncooperative task.
func boundedSaveTestValue<Value: Sendable, Failure: Error>(
    _ task: Task<Value, Failure>,
    timeout: Duration = .seconds(3)
) async throws -> Value {
    let result = SaveTestResult<Value, Failure>()
    let observer = Task { result.store(await task.result) }
    defer { observer.cancel() }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        if let completed = result.value { return try completed.get() }
        guard ContinuousClock.now < deadline else {
            task.cancel()
            throw SaveTestWaitError.timedOut
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private final class SaveTestResult<Value, Failure: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Failure>?
    var value: Result<Value, Failure>? { lock.withLock { result } }
    func store(_ result: Result<Value, Failure>) { lock.withLock { self.result = result } }
}

actor SaveTestGate {
    private nonisolated let entered = XCTestExpectation(description: "Save operation paused")
    private var released = false

    func pause(ignoringCancellation: Bool = false) async throws {
        entered.fulfill()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw SaveTestWaitError.timedOut }
            if ignoringCancellation {
                // An already-started writer can deliver its real result after waiter cancellation.
                await Task.detached { try? await Task.sleep(for: .milliseconds(1)) }.value
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    nonisolated func waitUntilPaused() async throws {
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed else {
            await release()
            throw SaveTestWaitError.timedOut
        }
    }

    func release() { released = true }
}

final class SaveTestWaitTests: XCTestCase {
    func testReleaseBeforePauseIsRetained() async throws {
        let gate = SaveTestGate()
        await gate.release()
        let pause = Task { try await gate.pause() }
        try await boundedSaveTestValue(pause)
    }

    func testTimeoutReturnsBeforeUncooperativeTaskCompletesAndAllowsCleanup() async throws {
        let gate = SaveTestGate()
        let task = Task { try await gate.pause(ignoringCancellation: true) }
        try await gate.waitUntilPaused()
        do {
            try await boundedSaveTestValue(task, timeout: .milliseconds(20))
            XCTFail("The task has not completed")
        } catch SaveTestWaitError.timedOut { }
        await gate.release()
        try await boundedSaveTestValue(task)
    }
}

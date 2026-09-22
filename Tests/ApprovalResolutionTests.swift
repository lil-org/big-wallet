import XCTest
@testable import Big_Wallet

@MainActor
final class ApprovalResolutionTests: XCTestCase {
    func testResolutionBeforeWaitingPreservesOptionalNil() async {
        let resolution = ApprovalResolution<Int?>()
        let first = await resolution.resolve(nil)
        let duplicate = await resolution.resolve(42)
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)

        let value = await resolution.value()
        let late = await resolution.resolve(43)

        XCTAssertNil(value)
        XCTAssertFalse(late)
    }

    func testWaitingResolutionRunsCleanupBeforeResuming() async {
        let resolution = ApprovalResolution<Int>()
        let cleanupGate = ApprovalResolution<Void>()
        let cleanupTask = Task { await cleanupGate.value() }
        let waiting = expectation(description: "waiter started")
        let waiter = Task {
            waiting.fulfill()
            let value = await resolution.value()
            XCTAssertTrue(cleanupTask.isCancelled)
            return value
        }
        await fulfillment(of: [waiting], timeout: 1)

        let resolved = await resolution.resolve(42) { cleanupTask.cancel() }
        let value = await waiter.value
        await cleanupGate.resolve(())
        await cleanupTask.value

        XCTAssertTrue(resolved)
        XCTAssertEqual(value, 42)
    }

    func testConcurrentResolutionsHaveOneWinnerAndIgnoreLateCleanup() async {
        let resolution = ApprovalResolution<Int>()
        let winners = await withTaskGroup(of: Int?.self) { group in
            for candidate in 0..<100 {
                group.addTask {
                    await resolution.resolve(candidate) ? candidate : nil
                }
            }
            var winners = [Int]()
            for await candidate in group {
                if let candidate { winners.append(candidate) }
            }
            return winners
        }
        let value = await resolution.value()
        let late = await resolution.resolve(-1) {
            XCTFail("A losing resolution must not run cleanup")
        }

        XCTAssertEqual(winners, [value])
        XCTAssertFalse(late)
    }

    func testConsumedResolutionDoesNotRetainItsValue() async {
        final class Value: Sendable {}
        let resolution = ApprovalResolution<Value>()
        var original: Value? = Value()
        weak let retained = original
        let resolved = await resolution.resolve(original!)
        original = nil
        XCTAssertTrue(resolved)
        XCTAssertNotNil(retained)

        var received: Value? = await resolution.value()
        XCTAssertTrue(received === retained)
        received = nil

        XCTAssertNil(retained)
    }

    func testTimeoutCancelsUncooperativeOperationAndIgnoresLateValue() async {
        let resolution = ApprovalResolution<Int>()
        let timeout = ApprovalResolution<Void>()
        let releaseOperation = ApprovalResolution<Void>()
        let started = expectation(description: "operation started")
        let returned = expectation(description: "late operation returned")
        let waiter = Task {
            await resolution.value(
                timeoutValue: -1,
                waitForTimeout: { await timeout.value() },
                operation: {
                    started.fulfill()
                    await releaseOperation.value()
                    XCTAssertTrue(Task.isCancelled)
                    returned.fulfill()
                    return 42
                }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        await timeout.resolve(())
        let value = await waiter.value
        XCTAssertEqual(value, -1)

        await releaseOperation.resolve(())
        await fulfillment(of: [returned], timeout: 1)
        let late = await resolution.resolve(43)
        XCTAssertFalse(late)
    }

    func testSuccessfulOperationCancelsTimerAndPreservesOptionalNil() async {
        let resolution = ApprovalResolution<Int?>()
        let releaseTimer = ApprovalResolution<Void>()
        let timerStarted = expectation(description: "timer started")
        let timerReturned = expectation(description: "canceled timer returned")
        let releaseOperation = ApprovalResolution<Void>()
        let waiter = Task {
            await resolution.value(
                timeoutValue: 42,
                waitForTimeout: {
                    timerStarted.fulfill()
                    await releaseTimer.value()
                    XCTAssertTrue(Task.isCancelled)
                    timerReturned.fulfill()
                },
                operation: {
                    await releaseOperation.value()
                    return nil
                }
            )
        }
        await fulfillment(of: [timerStarted], timeout: 1)
        await releaseOperation.resolve(())
        let value = await waiter.value
        XCTAssertNil(value)

        await releaseTimer.resolve(())
        await fulfillment(of: [timerReturned], timeout: 1)
        let late = await resolution.resolve(43)
        XCTAssertFalse(late)
    }
}

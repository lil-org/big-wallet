import XCTest
@testable import Big_Wallet

private func blockApprovalResolutionOperation(_ signal: DispatchSemaphore) {
    signal.wait()
}

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
        let cleanupGate = TestGate<Void>()
        let cleanupTask = Task { await cleanupGate.wait() }
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
        cleanupGate.resolve(())
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

    func testOperationWithoutTimeoutPreservesOptionalNil() async {
        let value = await ApprovalResolution<Int?>().value(
            timeoutValue: -1,
            callerCancellation: .resolveTimeout,
            operation: { nil }
        )

        XCTAssertNil(value)
    }

    func testCancellationWithoutTimeoutDiscardsUncooperativeOperationResult() async {
        let releaseOperation = TestGate<Void>()
        let started = expectation(description: "operation started")
        let completed = expectation(description: "caller returns before operation")
        let discarded = expectation(description: "late result discarded once")
        discarded.assertForOverFulfill = true
        let waiter = Task {
            let value = await ApprovalResolution<Int>().value(
                timeoutValue: -1,
                callerCancellation: .resolveTimeout,
                onDiscardedValue: { value in
                    XCTAssertEqual(value, 42)
                    discarded.fulfill()
                },
                operation: {
                    started.fulfill()
                    await releaseOperation.wait()
                    XCTAssertTrue(Task.isCancelled)
                    return 42
                }
            )
            completed.fulfill()
            return value
        }
        await fulfillment(of: [started], timeout: 1)
        waiter.cancel()
        await fulfillment(of: [completed], timeout: 1)
        releaseOperation.resolve(())
        let value = await waiter.value

        XCTAssertEqual(value, -1)
        await fulfillment(of: [discarded], timeout: 1)
    }

    func testTimeoutCancelsUncooperativeOperationAndIgnoresLateValue() async {
        let resolution = ApprovalResolution<Int>()
        let timeout = TestGate<Void>()
        let releaseOperation = TestGate<Void>()
        let started = expectation(description: "operation started")
        let returned = expectation(description: "late operation returned")
        let discarded = expectation(description: "late result discarded once")
        discarded.assertForOverFulfill = true
        let waiter = Task {
            await resolution.value(
                timeoutValue: -1,
                callerCancellation: .ignore,
                waitForTimeout: { await timeout.wait() },
                onDiscardedValue: { value in
                    XCTAssertEqual(value, 42)
                    discarded.fulfill()
                },
                operation: {
                    started.fulfill()
                    await releaseOperation.wait()
                    XCTAssertTrue(Task.isCancelled)
                    returned.fulfill()
                    return 42
                }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        timeout.resolve(())
        let value = await waiter.value
        XCTAssertEqual(value, -1)

        releaseOperation.resolve(())
        await fulfillment(of: [returned, discarded], timeout: 1)
        let late = await resolution.resolve(43)
        XCTAssertFalse(late)
    }

    func testBlockingOperationCannotBlockTheResolutionDeadline() async {
        let timeout = TestGate<Void>()
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "blocking operation started")
        let finished = expectation(description: "deadline resolved independently")
        let task = Task {
            let result = await ApprovalResolution<Int>().value(
                timeoutValue: -1,
                callerCancellation: .ignore,
                waitForTimeout: { await timeout.wait() },
                operation: {
                    started.fulfill()
                    blockApprovalResolutionOperation(release)
                    return 42
                }
            )
            finished.fulfill()
            return result
        }
        await fulfillment(of: [started], timeout: 1)
        timeout.resolve(())
        await fulfillment(of: [finished], timeout: 1)
        release.signal()
        let result = await task.value
        XCTAssertEqual(result, -1)
    }

    func testSuccessfulOperationCancelsTimerAndPreservesOptionalNil() async {
        let resolution = ApprovalResolution<Int?>()
        let releaseTimer = TestGate<Void>()
        let timerStarted = expectation(description: "timer started")
        let timerReturned = expectation(description: "canceled timer returned")
        let releaseOperation = TestGate<Void>()
        let waiter = Task {
            await resolution.value(
                timeoutValue: 42,
                callerCancellation: .ignore,
                waitForTimeout: {
                    timerStarted.fulfill()
                    await releaseTimer.wait()
                    XCTAssertTrue(Task.isCancelled)
                    timerReturned.fulfill()
                },
                onDiscardedValue: { _ in XCTFail("Winning value must not be discarded") },
                operation: {
                    await releaseOperation.wait()
                    return nil
                }
            )
        }
        await fulfillment(of: [timerStarted], timeout: 1)
        releaseOperation.resolve(())
        let value = await waiter.value
        XCTAssertNil(value)

        releaseTimer.resolve(())
        await fulfillment(of: [timerReturned], timeout: 1)
        let late = await resolution.resolve(43)
        XCTAssertFalse(late)
    }

    func testIgnoringCallerCancellationPreservesStartedAndNotYetStartedWork() async {
        for alreadyCancelled in [false, true] {
            let entry = TestGate<Void>()
            let releaseOperation = TestGate<Void>()
            let releaseTimer = TestGate<Void>()
            let started = expectation(description: "operation started")
            let timerReturned = expectation(description: "timer released")
            let waiter = Task {
                await entry.wait()
                return await ApprovalResolution<Int>().value(
                    timeoutValue: -1,
                    callerCancellation: .ignore,
                    waitForTimeout: {
                        await releaseTimer.wait()
                        timerReturned.fulfill()
                    },
                    onDiscardedValue: { _ in XCTFail("Approved work must survive caller cancellation") },
                    operation: {
                        XCTAssertFalse(Task.isCancelled)
                        started.fulfill()
                        await releaseOperation.wait()
                        XCTAssertFalse(Task.isCancelled)
                        return 42
                    }
                )
            }
            if alreadyCancelled { waiter.cancel() }
            entry.resolve(())
            await fulfillment(of: [started], timeout: 1)
            if !alreadyCancelled { waiter.cancel() }
            releaseOperation.resolve(())
            let value = await waiter.value
            XCTAssertEqual(value, 42)
            releaseTimer.resolve(())
            await fulfillment(of: [timerReturned], timeout: 1)
        }
    }

    func testCallerCancellationReturnsBeforeUncooperativeWorkAndDiscardsItsResult() async {
        let releaseOperation = TestGate<Void>()
        let releaseTimer = TestGate<Void>()
        let started = expectation(description: "operation started")
        let discarded = expectation(description: "canceled result discarded once")
        discarded.assertForOverFulfill = true
        let timerReturned = expectation(description: "timer released")
        let completed = expectation(description: "caller returns before uncooperative work")
        let waiter = Task {
            let value = await ApprovalResolution<Int>().value(
                timeoutValue: -1,
                callerCancellation: .resolveTimeout,
                waitForTimeout: {
                    await releaseTimer.wait()
                    timerReturned.fulfill()
                },
                onDiscardedValue: { value in
                    XCTAssertEqual(value, 42)
                    discarded.fulfill()
                },
                operation: {
                    started.fulfill()
                    await releaseOperation.wait()
                    XCTAssertTrue(Task.isCancelled)
                    return 42
                }
            )
            completed.fulfill()
            return value
        }
        await fulfillment(of: [started], timeout: 1)
        waiter.cancel()
        await fulfillment(of: [completed], timeout: 1)
        releaseOperation.resolve(())
        releaseTimer.resolve(())
        let value = await waiter.value
        XCTAssertEqual(value, -1)
        await fulfillment(of: [discarded, timerReturned], timeout: 1)
    }

    func testAlreadyCancelledCallerDoesNotStartWorkOrReplaceAnExistingWinner() async {
        for existingWinner in [nil, 42] as [Int?] {
            let resolution = ApprovalResolution<Int>()
            if let existingWinner { await resolution.resolve(existingWinner) }
            let entry = TestGate<Void>()
            let waiter = Task {
                await entry.wait()
                return await resolution.value(
                    timeoutValue: -1,
                    callerCancellation: .resolveTimeout,
                    waitForTimeout: { XCTFail("Already canceled race must not start a timer") },
                    operation: {
                        XCTFail("Already canceled race must not start work")
                        return 0
                    }
                )
            }
            waiter.cancel()
            entry.resolve(())
            let value = await waiter.value
            XCTAssertEqual(value, existingWinner ?? -1)
        }
    }

    func testCallerCancellationImmediatelyReachesTheRunningOperation() async {
        let releaseOperation = TestGate<Void>()
        let releaseTimer = TestGate<Void>()
        let discarded = expectation(description: "operation released")
        let timerReturned = expectation(description: "timer released")
        let completed = expectation(description: "caller returns after cancellation")
        var waiter: Task<Int, Never>!
        waiter = Task {
            let value = await ApprovalResolution<Int>().value(
                timeoutValue: -1,
                callerCancellation: .resolveTimeout,
                waitForTimeout: {
                    await releaseTimer.wait()
                    timerReturned.fulfill()
                },
                onDiscardedValue: { _ in discarded.fulfill() },
                operation: { @MainActor in
                    waiter.cancel()
                    XCTAssertTrue(Task.isCancelled)
                    await releaseOperation.wait()
                    return 42
                }
            )
            completed.fulfill()
            return value
        }
        await fulfillment(of: [completed], timeout: 1)
        releaseOperation.resolve(())
        releaseTimer.resolve(())
        let value = await waiter.value
        XCTAssertEqual(value, -1)
        await fulfillment(of: [discarded, timerReturned], timeout: 1)
    }
}

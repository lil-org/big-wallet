import Foundation
import XCTest

@MainActor
final class AsyncTestSupportTests: XCTestCase {
    func testGatePreservesPreResolvedNilAndSharesOneResolution() async {
        let gate = TestGate<Int?>()
        XCTAssertTrue(gate.resolve(nil))
        XCTAssertFalse(gate.resolve(42))
        let first = await gate.wait()
        let second = await gate.wait()
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    func testGateDeliversToMultipleWaitersDespiteCancellation() async {
        let gate = TestGate<Int>()
        let entered = expectation(description: "both waiters entered")
        entered.expectedFulfillmentCount = 2
        let tasks = (0..<2).map { _ in
            Task {
                entered.fulfill()
                return await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        tasks[0].cancel()
        XCTAssertTrue(gate.resolve(7))
        for task in tasks {
            let result = await task.value
            XCTAssertEqual(result, 7)
        }
        XCTAssertFalse(gate.resolve(8))
    }

    func testDeferredPreservesPreResolvedNilAndRejectsDuplicateResults() async throws {
        let deferred = TestDeferred<Int?>()
        XCTAssertTrue(deferred.resolve(.success(nil)))
        XCTAssertFalse(deferred.resolve(.success(42)))
        let value = try await deferred.value()
        XCTAssertNil(value)
        XCTAssertFalse(deferred.resolve(.success(9)))
    }

    func testDeferredCancellationBeforeRegistrationOverridesUndeliveredResult() async {
        let start = TestGate<Void>()
        let deferred = TestDeferred<Int>()
        deferred.resolve(.success(7))
        let task = Task {
            await start.wait()
            return try await deferred.value()
        }
        task.cancel()
        start.resolve(())
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(deferred.isCancelled)
        XCTAssertFalse(deferred.resolve(.success(9)))
    }

    func testDeferredCancellationRacesResolutionWithoutLosingConsumer() async {
        for _ in 0..<100 {
            let deferred = TestDeferred<Int>()
            let consumer = Task.detached { try await deferred.value() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { consumer.cancel() }
                group.addTask { deferred.resolve(.success(7)) }
            }
            do {
                let value = try await consumer.value
                XCTAssertEqual(value, 7)
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(deferred.resolve(.success(9)))
        }
    }

    func testClockSeparatesWallTimeFromMonotonicTime() {
        let clock = TestClock()
        let date = clock.date
        let uptime = clock.uptimeNanoseconds
        let instant = clock.instant
        clock.setDate(date.addingTimeInterval(-3_600))
        XCTAssertEqual(clock.uptimeNanoseconds, uptime)
        XCTAssertEqual(clock.instant, instant)
        clock.advanceUptime(by: 2_000_000_000)
        XCTAssertEqual(clock.date, date.addingTimeInterval(-3_600))
        XCTAssertEqual(clock.instant, instant.advanced(by: .seconds(2)))
        clock.advance(by: 3_000_000_000)
        XCTAssertEqual(clock.date, date.addingTimeInterval(-3_597))
        XCTAssertEqual(clock.uptimeNanoseconds, uptime + 5_000_000_000)
    }

    func testClockWakesOnlyDueSleepersAndCanAdvanceOffMainActor() async throws {
        let clock = TestClock()
        let registered = expectation(description: "both sleeps registered")
        registered.expectedFulfillmentCount = 2
        clock.onRegistration = { _ in registered.fulfill() }
        let first = Task { try await clock.sleep(for: 1_000_000_000) }
        let second = Task { try await clock.sleep(for: 2_000_000_000) }
        defer { first.cancel(); second.cancel() }
        await fulfillment(of: [registered], timeout: 2)
        await Task.detached { clock.advance(by: 1_000_000_000) }.value
        try await first.value
        XCTAssertEqual(clock.pendingSleeps.count, 1)
        clock.advance(by: 1_000_000_000)
        try await second.value
        XCTAssertTrue(clock.pendingSleeps.isEmpty)
        XCTAssertEqual(clock.registrations.map(\.durationNanoseconds).sorted(), [1_000_000_000, 2_000_000_000])
    }

    func testClockEarlyWakeDoesNotAdvanceTime() async throws {
        let clock = TestClock()
        let registered = expectation(description: "sleep registered")
        clock.onRegistration = { _ in registered.fulfill() }
        let task = Task { try await clock.sleep(for: 9_000_000_000) }
        defer { task.cancel() }
        await fulfillment(of: [registered], timeout: 2)
        let sleep = try XCTUnwrap(clock.pendingSleeps.first)
        XCTAssertTrue(clock.wake(sleep.id))
        try await task.value
        XCTAssertEqual(clock.uptimeNanoseconds, sleep.startedAt)
        XCTAssertFalse(clock.wake(sleep.id))
    }

    func testClockImmediateWakeRemainsActiveUntilCompletion() async throws {
        let clock = TestClock()
        let completed = expectation(description: "immediately awakened sleep completed")
        clock.onRegistration = { [weak clock] sleep in
            guard let clock else { return XCTFail("Clock disappeared during registration") }
            XCTAssertEqual(clock.activeSleepCount, 1)
            XCTAssertTrue(clock.wake(sleep.id))
            XCTAssertTrue(clock.pendingSleeps.isEmpty)
            XCTAssertEqual(clock.activeSleepCount, 1)
        }
        clock.onCompletion = { [weak clock] _ in
            guard let clock else { return XCTFail("Clock disappeared during completion") }
            XCTAssertEqual(clock.activeSleepCount, 0)
            XCTAssertTrue(clock.pendingSleeps.isEmpty)
            completed.fulfill()
        }
        try await clock.sleep(for: 1_000_000_000)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(clock.registrations.count, 1)
    }

    func testClockCancellationRemovesOnlyItsOwnSleep() async throws {
        let clock = TestClock()
        let registered = expectation(description: "both sleeps registered")
        registered.expectedFulfillmentCount = 2
        clock.onRegistration = { _ in registered.fulfill() }
        let first = Task { try await clock.sleep(for: 9_000_000_000) }
        let second = Task { try await clock.sleep(for: 9_000_000_000) }
        defer { first.cancel(); second.cancel() }
        await fulfillment(of: [registered], timeout: 2)
        first.cancel()
        do {
            try await first.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(clock.pendingSleeps.count, 1)
        clock.advance(by: 9_000_000_000)
        try await second.value
        XCTAssertTrue(clock.pendingSleeps.isEmpty)
    }

    func testClockCancellationDuringRegistrationCannotStrandSleep() async {
        let clock = TestClock()
        clock.onRegistration = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task.detached { try await clock.sleep(for: 9_000_000_000) }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(clock.pendingSleeps.isEmpty)
    }
}

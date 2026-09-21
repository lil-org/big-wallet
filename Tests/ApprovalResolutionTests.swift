import XCTest
@testable import Big_Wallet

@MainActor
final class ApprovalResolutionTests: XCTestCase {
    func testResolutionBeforeWaitingPreservesOptionalNil() async {
        let resolution = ApprovalResolution<Int?>()
        XCTAssertTrue(resolution.resolve(nil))
        XCTAssertFalse(resolution.resolve(42))

        let value = await resolution.value()

        XCTAssertNil(value)
        XCTAssertFalse(resolution.resolve(43))
    }

    func testWaitingResolutionRunsCleanupBeforeResuming() async {
        let resolution = ApprovalResolution<Int>()
        let waiting = expectation(description: "waiter started")
        var events = [String]()
        let waiter = Task { @MainActor in
            waiting.fulfill()
            let value = await resolution.value()
            events.append("resumed")
            return value
        }
        await fulfillment(of: [waiting], timeout: 1)

        XCTAssertTrue(resolution.resolve(42) {
            events.append("cleanup")
        })
        let value = await waiter.value

        XCTAssertEqual(value, 42)
        XCTAssertEqual(events, ["cleanup", "resumed"])
    }

    func testFirstResolutionIgnoresReentrantAndLateCleanup() async {
        let resolution = ApprovalResolution<Int>()
        var cleanups = 0

        XCTAssertTrue(resolution.resolve(42) {
            cleanups += 1
            XCTAssertFalse(resolution.resolve(43) { cleanups += 1 })
        })
        let value = await resolution.value()
        XCTAssertFalse(resolution.resolve(44) { cleanups += 1 })

        XCTAssertEqual(value, 42)
        XCTAssertEqual(cleanups, 1)
    }

    func testConsumedResolutionDoesNotRetainItsValue() async {
        final class Value {}
        let resolution = ApprovalResolution<Value>()
        var original: Value? = Value()
        weak let retained = original
        XCTAssertTrue(resolution.resolve(original!))
        original = nil
        XCTAssertNotNil(retained)

        var received: Value? = await resolution.value()
        XCTAssertTrue(received === retained)
        received = nil

        XCTAssertNil(retained)
    }
}

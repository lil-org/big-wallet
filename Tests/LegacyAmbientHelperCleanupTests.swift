// ∅ 2026 lil org

#if os(macOS)
import Darwin
import Dispatch
import XCTest
@testable import Big_Wallet

final class LegacyAmbientHelperCleanupTests: XCTestCase {

    func testCleanupKillsAndForceTerminatesEveryLegacyAmbientProcess() {
        var requestedBundleIdentifiers: [String] = []
        var kills: [(pid_t, Int32)] = []
        var forceTerminations: [pid_t] = []
        let processIdentifiers: [pid_t] = [101, 202]
        let cleanup = LegacyAmbientHelperCleanup(
            runningApplications: { bundleIdentifier in
                requestedBundleIdentifiers.append(bundleIdentifier)
                return processIdentifiers.map { processIdentifier in
                    return LegacyAmbientHelperProcess(
                        processIdentifier: processIdentifier,
                        terminate: {
                            forceTerminations.append(processIdentifier)
                            return true
                        }
                    )
                }
            },
            kill: { processIdentifier, signal in
                kills.append((processIdentifier, signal))
                return true
            }
        )

        XCTAssertTrue(cleanup.run())

        XCTAssertEqual(requestedBundleIdentifiers, ["org.lil.wallet.ambient"])
        XCTAssertEqual(kills.map(\.0), processIdentifiers)
        XCTAssertEqual(kills.map(\.1), [SIGKILL, SIGKILL])
        XCTAssertEqual(forceTerminations, processIdentifiers)
    }

    func testCleanupCanRunAgainAfterLegacyProcessesAreGone() {
        var processIsRunning = true
        var killCount = 0
        var forceTerminateCount = 0
        let cleanup = LegacyAmbientHelperCleanup(
            runningApplications: { _ in
                guard processIsRunning else { return [] }
                processIsRunning = false
                return [LegacyAmbientHelperProcess(
                    processIdentifier: 303,
                    terminate: {
                        forceTerminateCount += 1
                        return true
                    }
                )]
            },
            kill: { _, _ in
                killCount += 1
                return true
            }
        )

        XCTAssertTrue(cleanup.run())
        XCTAssertTrue(cleanup.run())

        XCTAssertEqual(killCount, 1)
        XCTAssertEqual(forceTerminateCount, 1)
    }

    func testCleanupWithNoLegacyProcessesHasNoSideEffects() {
        var killCount = 0
        let cleanup = LegacyAmbientHelperCleanup(
            runningApplications: { _ in [] },
            kill: { _, _ in
                killCount += 1
                return false
            }
        )

        XCTAssertTrue(cleanup.run())

        XCTAssertEqual(killCount, 0)
    }

    func testCleanupSucceedsWhenEitherTerminationMechanismIsAccepted() {
        let signalAccepted = LegacyAmbientHelperCleanup(
            runningApplications: { _ in [
                LegacyAmbientHelperProcess(
                    processIdentifier: 404,
                    terminate: { false }
                ),
            ] },
            kill: { _, _ in true }
        )
        let requestAccepted = LegacyAmbientHelperCleanup(
            runningApplications: { _ in [
                LegacyAmbientHelperProcess(
                    processIdentifier: 505,
                    terminate: { true }
                ),
            ] },
            kill: { _, _ in false }
        )

        XCTAssertTrue(signalAccepted.run())
        XCTAssertTrue(requestAccepted.run())
    }

    func testCleanupFailsWhenTerminationCannotBeInitiatedForEveryProcess() {
        let cleanup = LegacyAmbientHelperCleanup(
            runningApplications: { _ in [
                LegacyAmbientHelperProcess(
                    processIdentifier: 606,
                    terminate: { true }
                ),
                LegacyAmbientHelperProcess(
                    processIdentifier: 707,
                    terminate: { false }
                ),
            ] },
            kill: { processIdentifier, _ in
                return processIdentifier == 606
            }
        )

        XCTAssertFalse(cleanup.run())
    }

    func testCleanupGateRunsOnlyOnceEvenWhenCleanupFails() {
        var attempts = 0
        let cleanup = LegacyAmbientHelperCleanup(
            runningApplications: { _ in [
                LegacyAmbientHelperProcess(
                    processIdentifier: 808,
                    terminate: { false }
                ),
            ] },
            kill: { _, _ in
                attempts += 1
                return false
            }
        )
        let gate = LegacyAmbientHelperCleanupGate(cleanup: cleanup)

        gate.runBestEffort()
        gate.runBestEffort()
        gate.runBestEffort()
        XCTAssertEqual(attempts, 1)
    }

    func testCleanupGateSynchronizesConcurrentCalls() {
        let firstAttemptStarted = DispatchSemaphore(value: 0)
        let finishFirstAttempt = DispatchSemaphore(value: 0)
        let resultsLock = NSLock()
        var cleanupCallCount = 0
        var completedCallCount = 0
        let cleanup = LegacyAmbientHelperCleanup(
            runningApplications: { _ in
                cleanupCallCount += 1
                firstAttemptStarted.signal()
                _ = finishFirstAttempt.wait(timeout: .now() + 2)
                return []
            },
            kill: { _, _ in false }
        )
        let gate = LegacyAmbientHelperCleanupGate(cleanup: cleanup)
        let group = DispatchGroup()

        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                gate.runBestEffort()
                resultsLock.lock()
                completedCallCount += 1
                resultsLock.unlock()
                group.leave()
            }
        }

        XCTAssertEqual(firstAttemptStarted.wait(timeout: .now() + 1), .success)
        finishFirstAttempt.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cleanupCallCount, 1)
        XCTAssertEqual(completedCallCount, 16)
    }

}
#endif

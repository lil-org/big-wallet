import Foundation
import Security
import Synchronization
import XCTest
@testable import WalletAuthority
@testable import Big_Wallet
#if os(macOS)
import AppKit
#endif

@MainActor
final class WalletAccessTestFixture {
    private final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(by duration: Duration) { instant.withLock { $0 += duration } }
    }

    @MainActor
    final class ScheduledExpiration {
        let delay: Duration
        let action: @MainActor () -> Void
        var cancelled = false

        init(delay: Duration, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }
    }

    @MainActor
    final class Scheduler: WalletAccessExpirationScheduling {
        var expirations = [ScheduledExpiration]()

        func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
            cancel()
            let expiration = ScheduledExpiration(delay: delay, action: action)
            expirations.append(expiration)
        }

        func cancel() { expirations.last?.cancelled = true }
    }

    let authorityID: UUID
    private let password: String
    let keychain = PasswordKeychainFixture()
    let credentials: WalletCredentials
    let access: WalletAccessController
    let scheduler: Scheduler
    private let time = Clock()

    init(authorityID: UUID = UUID(), password: String = "password") {
        self.authorityID = authorityID
        self.password = password
        keychain.passwordData = Data(password.utf8)
        let time = time
#if os(iOS) || os(visionOS)
        let vault = SafariApprovalVault(fileURL: nil)
        let host = SafariApprovalVaultHost(vault: vault, sourceSnapshot: { nil })
        credentials = WalletCredentials(keychain: keychain.keychain, messages: .testingEnglish, authorityID: authorityID, vaultHost: host, accessClock: { time.now })
#else
        credentials = WalletCredentials(keychain: keychain.keychain, messages: .testingEnglish, authorityID: authorityID, accessClock: { time.now })
#endif
        let scheduler = Scheduler()
        self.scheduler = scheduler
        access = WalletAccessController(credentials: credentials, expirationScheduler: scheduler, activityClock: { time.now })
    }

    func advance(by duration: Duration) {
        time.advance(by: duration)
    }

    func makeSession() throws -> WalletAccessSession {
        let challenge = credentials.makeWalletAccessChallenge()
        let grant = try XCTUnwrap(credentials.verify(password: password, challenge: challenge))
        return try XCTUnwrap(credentials.accessSession(authorization: grant))
    }

    @discardableResult
    func unlock() throws -> WalletAccessSession {
        let attempt = access.beginAuthentication(onCancelled: { _ in })
        let session = try makeSession()
        XCTAssertTrue(attempt.complete(session))
        return session
    }
}

@MainActor
func unlockedWalletAccessForTesting() throws -> WalletAccessController {
    let fixture = WalletAccessTestFixture()
    try fixture.unlock()
    return fixture.access
}

@MainActor
final class WalletAccessControllerTests: XCTestCase {
    func testExpiryIsEnforcedBeforeAnActionWithoutTimerDelivery() throws {
        let fixture = WalletAccessTestFixture()
        let session = try fixture.unlock()
        let generation = fixture.access.generation
        fixture.advance(by: .seconds(900))

        XCTAssertFalse(fixture.access.recordInteraction())
        XCTAssertFalse(fixture.access.validateCurrentAccess(expectedGeneration: generation))
        XCTAssertTrue(fixture.access.isLocked)
        XCTAssertEqual(fixture.access.lockReason, .idle)
        XCTAssertFalse(fixture.credentials.validateAccess(session))
    }

    func testOldTimersCannotLockARenewedOrReplacementSession() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let first = try XCTUnwrap(fixture.scheduler.expirations.first)
        fixture.advance(by: .seconds(899))
        XCTAssertTrue(fixture.access.recordInteraction())
        XCTAssertTrue(first.cancelled)
        let renewed = try XCTUnwrap(fixture.scheduler.expirations.last)
        fixture.advance(by: .seconds(1))
        first.action()
        XCTAssertTrue(fixture.access.validateCurrentAccess())

        fixture.access.lock(reason: .background)
        let replacement = try fixture.unlock()
        renewed.action()
        XCTAssertTrue(fixture.access.validateCurrentAccess())
        XCTAssertTrue(fixture.access.session === replacement)
    }

    func testEarlyTimerDeliveryReschedulesOnlyRemainingTime() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        fixture.advance(by: .seconds(400))
        fixture.scheduler.expirations[0].action()
        XCTAssertEqual(fixture.scheduler.expirations.last?.delay, .seconds(500))
        XCTAssertFalse(fixture.access.isLocked)
        fixture.advance(by: .seconds(500))
        fixture.scheduler.expirations.last?.action()
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testContinuousInputCoalescesRenewalsWithoutChangingActionExpiryChecks() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        fixture.access.recordContinuousInteraction()
        let count = fixture.scheduler.expirations.count
        for _ in 0..<100 { fixture.access.recordContinuousInteraction() }
        XCTAssertEqual(fixture.scheduler.expirations.count, count)
        fixture.advance(by: .seconds(1))
        fixture.access.recordContinuousInteraction()
        XCTAssertEqual(fixture.scheduler.expirations.count, count + 1)
        fixture.access.session?.invalidate()
        XCTAssertFalse(fixture.access.validateCurrentAccess())
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testLockInvalidatesAccessBeforeCancellingAuthenticationAndNotifying() throws {
        let fixture = WalletAccessTestFixture()
        let session = try fixture.unlock()
        var cancelledWhileLocked = false
        var notifiedWhileLocked = false
        let observer = Observer()
        observer.onLock = {
            notifiedWhileLocked = fixture.access.isLocked && !fixture.credentials.validateAccess(session)
        }
        fixture.access.addObserver(observer)
        let attempt = fixture.access.beginAuthentication { _ in
            cancelledWhileLocked = fixture.access.isLocked && !fixture.credentials.validateAccess(session)
        }
        fixture.access.lock(reason: .systemSleep)
        XCTAssertTrue(cancelledWhileLocked)
        XCTAssertTrue(notifiedWhileLocked)
        let late = try fixture.makeSession()
        XCTAssertFalse(attempt.complete(late))
        XCTAssertFalse(fixture.credentials.validateAccess(late))
    }

    func testOldAuthenticationCannotReplaceNewAuthenticationOrUnlockAfterLock() throws {
        let fixture = WalletAccessTestFixture()
        var oldCancelled = 0
        let first = fixture.access.beginAuthentication { _ in oldCancelled += 1 }
        let oldSession = try fixture.makeSession()
        let second = fixture.access.beginAuthentication(onCancelled: { _ in })
        XCTAssertEqual(oldCancelled, 1)
        guard !first.complete(oldSession) else {
            return XCTFail("SECURITY-MUTATION[access.stale-authentication]")
        }
        let replacement = try fixture.makeSession()
        XCTAssertTrue(second.complete(replacement))
        first.cancel()
        XCTAssertTrue(fixture.access.validateCurrentAccess())

        fixture.access.lock(reason: .sessionInactive)
        XCTAssertFalse(first.complete(oldSession), "SECURITY-MUTATION[access.stale-authentication]")
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testPendingAuthenticationIdentityDoesNotReadCredentialsOrProtectedData() {
        let fixture = WalletAccessTestFixture()
        let attempt = fixture.access.beginAuthentication(onCancelled: { _ in })
        let operation = attempt.replaceOperation()
        let reads = fixture.keychain.passwordReadCount
        fixture.access.isProtectedDataAvailable = {
            XCTFail("Pending authentication identity must not inspect protected data")
            return false
        }
        fixture.keychain.readStatus = errSecInteractionNotAllowed

        for _ in 0..<100 {
            XCTAssertTrue(attempt.isCurrent)
            XCTAssertTrue(operation.isCurrent)
        }

        XCTAssertEqual(fixture.keychain.passwordReadCount, reads)
        attempt.cancel()
        XCTAssertFalse(attempt.isCurrent)
        XCTAssertFalse(operation.isCurrent)
    }

    func testReplacingAnOperationRejectsItsLateGrantAndSession() throws {
        let fixture = WalletAccessTestFixture()
        let attempt = fixture.access.beginAuthentication(onCancelled: { _ in })
        let firstChallenge = fixture.credentials.makeWalletAccessChallenge()
        let grant = try XCTUnwrap(fixture.credentials.verify(password: "password", challenge: firstChallenge))
        let first = attempt.replaceOperation(challenge: firstChallenge)
        let secondChallenge = fixture.credentials.makeWalletAccessChallenge()
        let second = attempt.replaceOperation(challenge: secondChallenge)

        XCTAssertTrue(attempt.isCurrent)
        XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(second.isCurrent)
        XCTAssertFalse(first.complete(grant))
        XCTAssertNil(fixture.credentials.accessSession(authorization: grant))
        let staleSession = try fixture.makeSession()
        XCTAssertFalse(first.complete(staleSession))
        XCTAssertFalse(fixture.credentials.validateAccess(staleSession))

        let replacement = try XCTUnwrap(fixture.credentials.verify(password: "password", challenge: secondChallenge))
        XCTAssertTrue(second.complete(replacement))
        XCTAssertFalse(attempt.isCurrent)
        XCTAssertFalse(second.isCurrent)
        XCTAssertTrue(fixture.access.validateCurrentAccess())
    }

    func testCancellationRetiresChallengeBeforeTaskAndOwnerCallbacks() async throws {
        let fixture = WalletAccessTestFixture()
        let credentials = fixture.credentials
        let authorityID = fixture.authorityID
        let challenge = credentials.makeWalletAccessChallenge()
        let entered = expectation(description: "Authentication work started")
        let cancelled = expectation(description: "Authentication work was cancelled")
        let finished = expectation(description: "Authentication work returned")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        let taskSawInvalidChallenge = Mutex(false)
        var callbackSawInvalidChallenge = false
        let attempt = fixture.access.beginAuthentication { retired in
            XCTAssertFalse(retired.isCurrent)
            callbackSawInvalidChallenge = !challenge.isPending(for: authorityID)
        }
        let operation = attempt.replaceOperation(challenge: challenge) { _ in
            await withTaskCancellationHandler {
                entered.fulfill()
                await release.wait()
            } onCancel: {
                taskSawInvalidChallenge.withLock { $0 = !challenge.isPending(for: authorityID) }
                cancelled.fulfill()
            }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)

        attempt.cancel()

        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(operation.isCurrent)
        XCTAssertTrue(callbackSawInvalidChallenge)
        XCTAssertTrue(taskSawInvalidChallenge.withLock { $0 })
        release.resolve(())
        await fulfillment(of: [finished], timeout: 2)
    }

    func testReentrantCancellationCannotOverwriteOrCancelTheReplacementAttempt() throws {
        let fixture = WalletAccessTestFixture()
        var replacement: WalletAccessController.AuthenticationAttempt?
        var interveningCancellations = 0
        let first = fixture.access.beginAuthentication { retired in
            XCTAssertFalse(retired.isCurrent)
            replacement = fixture.access.beginAuthentication(onCancelled: { _ in })
        }

        let intervening = fixture.access.beginAuthentication { retired in
            XCTAssertFalse(retired.isCurrent)
            interveningCancellations += 1
        }

        let current = try XCTUnwrap(replacement)
        XCTAssertFalse(first.isCurrent)
        XCTAssertFalse(intervening.isCurrent)
        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(interveningCancellations, 1)
        let generation = fixture.access.generation
        intervening.cancel()
        XCTAssertEqual(fixture.access.generation, generation)
        let staleSession = try fixture.makeSession()
        XCTAssertFalse(intervening.complete(staleSession))
        XCTAssertFalse(fixture.credentials.validateAccess(staleSession))
        XCTAssertTrue(current.complete(try fixture.makeSession()))
    }

    func testSuccessfulOperationDetachesBeforeObserversWithoutCancellingItself() async throws {
        let fixture = WalletAccessTestFixture()
        var cancellations = 0
        let attempt = fixture.access.beginAuthentication { _ in cancellations += 1 }
        let observer = Observer()
        observer.onUnlock = {
            XCTAssertFalse(attempt.isCurrent)
            attempt.cancel()
            XCTAssertFalse(fixture.access.isLocked)
        }
        fixture.access.addObserver(observer)
        let session = try fixture.makeSession()
        let completed = expectation(description: "Authentication completion returned")
        let generation = fixture.access.generation
        let operation = attempt.replaceOperation { operation in
            XCTAssertTrue(operation.complete(session))
            XCTAssertFalse(operation.isCurrent)
            XCTAssertFalse(Task.isCancelled)
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)

        XCTAssertFalse(operation.isCurrent)
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(fixture.access.generation, generation)
        XCTAssertTrue(fixture.credentials.validateAccess(session))
        XCTAssertTrue(fixture.access.session === session)
    }

    func testRetainedAuthenticationWorkIsInvalidatedWhenItsControllerDeallocates() async throws {
        let fixture = WalletAccessTestFixture()
        let credentials = fixture.credentials
        var access: WalletAccessController? = WalletAccessController(credentials: credentials)
        weak var retained = access
        var cancellations = 0
        let attempt = try XCTUnwrap(access?.beginAuthentication { _ in cancellations += 1 })
        let challenge = credentials.makeWalletAccessChallenge()
        let entered = expectation(description: "Owned work started")
        let cancelled = expectation(description: "Owner release cancelled work")
        let finished = expectation(description: "Retired work returned")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        let operation = attempt.replaceOperation(challenge: challenge) { _ in
            await withTaskCancellationHandler {
                entered.fulfill()
                await release.wait()
            } onCancel: { cancelled.fulfill() }
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)

        access = nil

        XCTAssertNil(retained)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(attempt.isCurrent)
        XCTAssertFalse(operation.isCurrent)
        XCTAssertFalse(challenge.isPending(for: fixture.authorityID))
        let lateChallenge = credentials.makeWalletAccessChallenge()
        XCTAssertFalse(operation.attachChallenge(lateChallenge))
        XCTAssertFalse(lateChallenge.isPending(for: fixture.authorityID))
        let unrelatedChallenge = credentials.makeWalletAccessChallenge()
        let lateGrant = try XCTUnwrap(credentials.verify(password: "password", challenge: unrelatedChallenge))
        XCTAssertFalse(operation.complete(lateGrant))
        XCTAssertNil(credentials.accessSession(authorization: lateGrant))
        let lateSession = try fixture.makeSession()
        XCTAssertFalse(attempt.complete(lateSession))
        XCTAssertFalse(credentials.validateAccess(lateSession))
        attempt.cancel()
        XCTAssertEqual(cancellations, 1)
        await fulfillment(of: [cancelled], timeout: 2)
        release.resolve(())
        await fulfillment(of: [finished], timeout: 2)
    }

    func testUIActivityAndTimersDoNotReadCredentials() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let reads = fixture.keychain.passwordReadCount
        let generation = fixture.access.generation
        fixture.keychain.readStatus = errSecInteractionNotAllowed
        for _ in 0..<100 {
            XCTAssertTrue(fixture.access.validateCurrentAccess())
            XCTAssertTrue(fixture.access.validateCurrentAccess(expectedGeneration: generation))
            XCTAssertTrue(fixture.access.recordInteraction())
            fixture.access.recordContinuousInteraction()
        }
        fixture.advance(by: .seconds(400))
        fixture.scheduler.expirations.last?.action()
        XCTAssertEqual(fixture.scheduler.expirations.last?.delay, .seconds(500))
        XCTAssertTrue(fixture.access.validateCurrentAccess())
        fixture.advance(by: .seconds(500))
        fixture.scheduler.expirations.last?.action()
        XCTAssertTrue(fixture.access.isLocked)
        XCTAssertFalse(fixture.access.recordInteraction())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads)
    }

    func testSensitiveOperationDetectsReplacementAndRetiresTheSessionPermanently() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let reads = fixture.keychain.passwordReadCount
        fixture.keychain.passwordData = Data("replacement".utf8)
        XCTAssertTrue(fixture.access.validateCurrentAccess())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads)
        XCTAssertThrowsError(try fixture.access.requireCurrentAccess())
        XCTAssertFalse(fixture.access.validateCurrentAccess())
        fixture.keychain.passwordData = Data("password".utf8)
        XCTAssertFalse(fixture.access.validateCurrentAccess())
        XCTAssertFalse(fixture.access.recordInteraction())
        XCTAssertTrue(fixture.access.hasLocked)
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 1)
    }

    func testSensitiveOperationFailsDuringKeychainOutageWithoutRevokingTheLease() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let reads = fixture.keychain.passwordReadCount
        fixture.keychain.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.access.requireCurrentAccess())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 1)
        XCTAssertTrue(fixture.access.validateCurrentAccess())
        XCTAssertTrue(fixture.access.recordInteraction())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 1)
        fixture.keychain.readStatus = nil
        XCTAssertNoThrow(try fixture.access.requireCurrentAccess())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 2)
    }

    func testProtectedDataLossRejectsAuthenticationBeforeAnEventIsDelivered() throws {
        let fixture = WalletAccessTestFixture()
        let attempt = fixture.access.beginAuthentication(onCancelled: { _ in })
        let session = try fixture.makeSession()
        fixture.access.isProtectedDataAvailable = { false }
        XCTAssertFalse(attempt.complete(session))
        XCTAssertEqual(fixture.access.lockReason, .protectedDataUnavailable)
        XCTAssertFalse(fixture.credentials.validateAccess(session))

        fixture.access.isProtectedDataAvailable = { true }
        try fixture.unlock()
        fixture.access.isProtectedDataAvailable = { false }
        XCTAssertFalse(fixture.access.recordInteraction())
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testLockObserverCannotReentrantlyUnlockOrPreventOtherTeardown() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let reentrantSession = try fixture.makeSession()
        var teardownCount = 0
        let first = Observer()
        let second = Observer()
        for observer in [first, second] {
            observer.onLock = {
                teardownCount += 1
                let attempt = fixture.access.beginAuthentication(onCancelled: { _ in })
                XCTAssertFalse(attempt.complete(reentrantSession))
                fixture.access.lock(reason: .idle)
            }
            fixture.access.addObserver(observer)
        }
        fixture.access.lock(reason: .background)
        XCTAssertEqual(teardownCount, 2)
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testLockDuringUnlockNotificationCannotPublishLaterUnlockCallbacks() throws {
        let fixture = WalletAccessTestFixture()
        let observer = Observer()
        observer.onUnlock = { fixture.access.lock(reason: .systemSleep) }
        fixture.access.addObserver(observer)
        let attempt = fixture.access.beginAuthentication(onCancelled: { _ in })
        let session = try fixture.makeSession()
        XCTAssertFalse(attempt.complete(session))
        XCTAssertTrue(fixture.access.isLocked)
        XCTAssertFalse(fixture.credentials.validateAccess(session))
    }

    func testPresentationMatchingHasNoValidationOrTimerSideEffects() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let generation = fixture.access.generation
        let reads = fixture.keychain.passwordReadCount
        let timers = fixture.scheduler.expirations.count
        var availabilityReads = 0
        fixture.access.isProtectedDataAvailable = { availabilityReads += 1; return false }
        fixture.advance(by: .seconds(900))
        for _ in 0..<10 {
            XCTAssertTrue(fixture.access.matchesPresentation(generation))
            XCTAssertFalse(fixture.access.matchesPresentation(generation &+ 1))
        }
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads)
        XCTAssertEqual(fixture.scheduler.expirations.count, timers)
        XCTAssertEqual(availabilityReads, 0)
        XCTAssertFalse(fixture.access.isLocked)
        XCTAssertFalse(fixture.access.validateCurrentAccess(expectedGeneration: generation))
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testStaleGenerationCannotValidateRenewOrLockAReplacementSession() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let old = fixture.access.generation
        fixture.access.lock(reason: .background)
        let current = try fixture.unlock()
        let generation = fixture.access.generation
        let timers = fixture.scheduler.expirations.count
        var availabilityReads = 0
        fixture.access.isProtectedDataAvailable = { availabilityReads += 1; return false }
        XCTAssertFalse(fixture.access.validateCurrentAccess(expectedGeneration: old))
        XCTAssertFalse(fixture.access.recordInteraction(expectedGeneration: old))
        XCTAssertThrowsError(try fixture.access.requireCurrentAccess(expectedGeneration: old))
        XCTAssertTrue(fixture.access.matchesPresentation(generation))
        XCTAssertTrue(fixture.access.session === current)
        XCTAssertEqual(availabilityReads, 0)
        XCTAssertEqual(fixture.scheduler.expirations.count, timers)
    }

    func testDeallocationInvalidatesAccessAndCancelsRetainedTimer() throws {
        let fixture = WalletAccessTestFixture()
        var access: WalletAccessController? = WalletAccessController(credentials: fixture.credentials, expirationScheduler: fixture.scheduler)
        let attempt = try XCTUnwrap(access?.beginAuthentication(onCancelled: { _ in }))
        let session = try fixture.makeSession()
        XCTAssertTrue(attempt.complete(session))
        let timer = try XCTUnwrap(fixture.scheduler.expirations.last)
        weak let retained = access
        access = nil
        XCTAssertNil(retained)
        XCTAssertTrue(timer.cancelled)
        XCTAssertFalse(fixture.credentials.validateAccess(session))
        timer.action()
        XCTAssertNil(retained)
    }

    func testDeallocationCancelsPendingAuthentication() {
        let fixture = WalletAccessTestFixture()
        var cancelled = false
        var access: WalletAccessController? = WalletAccessController(credentials: fixture.credentials)
        access?.beginAuthentication { _ in cancelled = true }
        access = nil
        XCTAssertTrue(cancelled)
    }

#if os(macOS)
    func testInactivityTimerExpiresInsideAnAppKitModalLoop() async throws {
        try await Task { @MainActor in
            let fixture = WalletAccessTestFixture()
            let access = WalletAccessController(credentials: fixture.credentials)
            let attempt = access.beginAuthentication(onCancelled: { _ in })
            let session = try fixture.makeSession()
            fixture.advance(by: .milliseconds(899_900))
            XCTAssertTrue(attempt.complete(session))
            fixture.advance(by: .seconds(1))
            let alert = NSAlert()
            alert.messageText = "Disposable wallet lock test"
            alert.addButton(withTitle: "OK")
            alert.window.alphaValue = 0
            alert.window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            let observer = Observer()
            var lockedWhileModal = false
            observer.onLock = {
                lockedWhileModal = NSApp.modalWindow === alert.window
                alert.buttons[0].performClick(nil)
            }
            access.addObserver(observer)
            let timeout = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.abortModal() }
            }
            RunLoop.main.add(timeout, forMode: .modalPanel)
            defer {
                timeout.invalidate()
                alert.window.orderOut(nil)
                access.lock(reason: .idle)
            }
            _ = alert.runModal()
            XCTAssertTrue(lockedWhileModal)
            XCTAssertTrue(access.isLocked)
        }.value
    }
#endif

    private final class Observer: WalletAccessObserver {
        var onLock: (() -> Void)?
        var onUnlock: (() -> Void)?
        func walletAccessDidLock() { onLock?() }
        func walletAccessDidUnlock() { onUnlock?() }
    }

}

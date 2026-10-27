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
    final class Scheduler {
        var expirations = [ScheduledExpiration]()

        func schedule(_ delay: Duration, action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            let expiration = ScheduledExpiration(delay: delay, action: action)
            expirations.append(expiration)
            return { expiration.cancelled = true }
        }
    }

    let keychain = PasswordKeychainFixture()
    let credentials: WalletCredentials
    let access: WalletAccessController
    let scheduler: Scheduler
    private let time = Clock()

    init() {
        keychain.passwordData = Data("password".utf8)
        let time = time
#if os(iOS) || os(visionOS)
        let vault = SafariApprovalVault(fileURL: nil)
        let host = SafariApprovalVaultHost(vault: vault, sourceSnapshot: { nil })
        credentials = WalletCredentials(keychain: keychain.keychain, messages: .testingEnglish, authorityID: UUID(), vaultHost: host, accessClock: { time.now })
#else
        credentials = WalletCredentials(keychain: keychain.keychain, messages: .testingEnglish, authorityID: UUID(), accessClock: { time.now })
#endif
        let scheduler = Scheduler()
        self.scheduler = scheduler
        access = WalletAccessController(credentials: credentials, schedule: scheduler.schedule, activityClock: { time.now })
    }

    func advance(by duration: Duration) {
        time.advance(by: duration)
    }

    func makeSession() throws -> WalletAccessSession {
        let challenge = credentials.makeWalletAccessChallenge()
        let grant = try XCTUnwrap(credentials.verify(password: "password", challenge: challenge))
        return try XCTUnwrap(credentials.accessSession(authorization: grant))
    }

    @discardableResult
    func unlock() throws -> WalletAccessSession {
        let generation = access.beginAuthentication(cancel: {})
        let session = try makeSession()
        XCTAssertTrue(access.completeAuthentication(session, generation: generation))
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
        XCTAssertFalse(fixture.access.accepts(generation))
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
        XCTAssertTrue(fixture.access.checkAccess())

        fixture.access.lock(reason: .background)
        let replacement = try fixture.unlock()
        renewed.action()
        XCTAssertTrue(fixture.access.checkAccess())
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
        XCTAssertFalse(fixture.access.checkAccess())
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
        let attempt = fixture.access.beginAuthentication {
            cancelledWhileLocked = fixture.access.isLocked && !fixture.credentials.validateAccess(session)
        }
        fixture.access.lock(reason: .systemSleep)
        XCTAssertTrue(cancelledWhileLocked)
        XCTAssertTrue(notifiedWhileLocked)
        let late = try fixture.makeSession()
        XCTAssertFalse(fixture.access.completeAuthentication(late, generation: attempt))
        XCTAssertFalse(fixture.credentials.validateAccess(late))
    }

    func testOldAuthenticationCannotReplaceNewAuthenticationOrUnlockAfterLock() throws {
        let fixture = WalletAccessTestFixture()
        var oldCancelled = 0
        let first = fixture.access.beginAuthentication { oldCancelled += 1 }
        let oldSession = try fixture.makeSession()
        let second = fixture.access.beginAuthentication(cancel: {})
        XCTAssertEqual(oldCancelled, 1)
        XCTAssertFalse(fixture.access.completeAuthentication(oldSession, generation: first))
        let replacement = try fixture.makeSession()
        XCTAssertTrue(fixture.access.completeAuthentication(replacement, generation: second))
        fixture.access.cancelAuthentication(generation: first)
        XCTAssertTrue(fixture.access.checkAccess())

        fixture.access.lock(reason: .sessionInactive)
        XCTAssertFalse(fixture.access.completeAuthentication(oldSession, generation: first))
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testUIActivityAndTimersDoNotReadCredentials() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let reads = fixture.keychain.passwordReadCount
        let generation = fixture.access.generation
        fixture.keychain.readStatus = errSecInteractionNotAllowed
        for _ in 0..<100 {
            XCTAssertTrue(fixture.access.checkAccess())
            XCTAssertTrue(fixture.access.accepts(generation))
            XCTAssertTrue(fixture.access.recordInteraction())
            fixture.access.recordContinuousInteraction()
        }
        fixture.advance(by: .seconds(400))
        fixture.scheduler.expirations.last?.action()
        XCTAssertEqual(fixture.scheduler.expirations.last?.delay, .seconds(500))
        XCTAssertTrue(fixture.access.checkAccess())
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
        XCTAssertTrue(fixture.access.checkAccess())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads)
        XCTAssertThrowsError(try fixture.access.requireCurrentCredentials())
        XCTAssertFalse(fixture.access.checkAccess())
        fixture.keychain.passwordData = Data("password".utf8)
        XCTAssertFalse(fixture.access.checkAccess())
        XCTAssertFalse(fixture.access.recordInteraction())
        XCTAssertTrue(fixture.access.hasLocked)
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 1)
    }

    func testSensitiveOperationFailsDuringKeychainOutageWithoutRevokingTheLease() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let reads = fixture.keychain.passwordReadCount
        fixture.keychain.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.access.requireCurrentCredentials())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 1)
        XCTAssertTrue(fixture.access.checkAccess())
        XCTAssertTrue(fixture.access.recordInteraction())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 1)
        fixture.keychain.readStatus = nil
        XCTAssertNoThrow(try fixture.access.requireCurrentCredentials())
        XCTAssertEqual(fixture.keychain.passwordReadCount, reads + 2)
    }

    func testProtectedDataLossRejectsAuthenticationBeforeAnEventIsDelivered() throws {
        let fixture = WalletAccessTestFixture()
        let attempt = fixture.access.beginAuthentication(cancel: {})
        let session = try fixture.makeSession()
        fixture.access.isProtectedDataAvailable = { false }
        XCTAssertFalse(fixture.access.completeAuthentication(session, generation: attempt))
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
                let attempt = fixture.access.beginAuthentication(cancel: {})
                XCTAssertFalse(fixture.access.completeAuthentication(reentrantSession, generation: attempt))
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
        let attempt = fixture.access.beginAuthentication(cancel: {})
        let session = try fixture.makeSession()
        XCTAssertFalse(fixture.access.completeAuthentication(session, generation: attempt))
        XCTAssertTrue(fixture.access.isLocked)
        XCTAssertFalse(fixture.credentials.validateAccess(session))
    }

    func testCredentialChangeDuringSchedulingCannotPublishAnUnlock() throws {
        let fixture = WalletAccessTestFixture()
        let access = WalletAccessController(credentials: fixture.credentials, schedule: { _, _ in
            fixture.keychain.passwordData = Data("replacement".utf8)
            return {}
        })
        let observer = Observer()
        var unlocked = false
        observer.onUnlock = { unlocked = true }
        access.addObserver(observer)
        let attempt = access.beginAuthentication(cancel: {})
        XCTAssertFalse(access.completeAuthentication(try fixture.makeSession(), generation: attempt))
        XCTAssertFalse(unlocked)
        XCTAssertTrue(access.isLocked)
    }

    func testSynchronousSchedulerLockCannotReportSuccessfulInteraction() throws {
        let fixture = WalletAccessTestFixture()
        let scheduling = ReentrantScheduler()
        let access = WalletAccessController(credentials: fixture.credentials, schedule: scheduling.schedule)
        scheduling.access = access
        let attempt = access.beginAuthentication(cancel: {})
        XCTAssertTrue(access.completeAuthentication(try fixture.makeSession(), generation: attempt))
        scheduling.shouldLock = true
        XCTAssertFalse(access.recordInteraction())
        XCTAssertTrue(access.isLocked)
    }

    func testDeallocationInvalidatesAccessAndCancelsRetainedTimer() throws {
        let fixture = WalletAccessTestFixture()
        var access: WalletAccessController? = WalletAccessController(credentials: fixture.credentials, schedule: fixture.scheduler.schedule)
        let attempt = try XCTUnwrap(access?.beginAuthentication(cancel: {}))
        let session = try fixture.makeSession()
        XCTAssertTrue(try XCTUnwrap(access?.completeAuthentication(session, generation: attempt)))
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
        access?.beginAuthentication { cancelled = true }
        access = nil
        XCTAssertTrue(cancelled)
    }

#if os(macOS)
    func testInactivityTimerExpiresInsideAnAppKitModalLoop() async throws {
        try await Task { @MainActor in
            let fixture = WalletAccessTestFixture()
            let access = WalletAccessController(credentials: fixture.credentials)
            let attempt = access.beginAuthentication(cancel: {})
            let session = try fixture.makeSession()
            fixture.advance(by: .milliseconds(899_900))
            XCTAssertTrue(access.completeAuthentication(session, generation: attempt))
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

    @MainActor
    private final class ReentrantScheduler {
        weak var access: WalletAccessController?
        var shouldLock = false

        func schedule(_ delay: Duration, action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            if shouldLock { access?.lock(reason: .systemSleep) }
            return {}
        }
    }
}

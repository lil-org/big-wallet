import Foundation
import XCTest
@testable import Big_Wallet

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class SecretHandlingTests: XCTestCase {
    func testInvalidationRejectsLateSecretResultsAndCallbacks() {
        let session = SecretPresentationSession()
        let token = session.begin()
        XCTAssertTrue(session.store("secret", for: token))
        let copyValue = { session.value(for: token) }
        XCTAssertEqual(copyValue(), "secret")

        session.invalidate()

        XCTAssertFalse(session.isCurrent(token))
        XCTAssertNil(session.value(for: token))
        XCTAssertNil(copyValue())
        XCTAssertFalse(session.store("late secret", for: token))
        XCTAssertNil(session.value(for: token))
    }

    func testNewPresentationClearsOldSecretAndRejectsOldTokens() {
        let session = SecretPresentationSession()
        let first = session.begin()
        XCTAssertTrue(session.store("first secret", for: first))

        let second = session.begin()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(session.isCurrent(first))
        XCTAssertTrue(session.isCurrent(second))
        XCTAssertNil(session.value(for: first))
        XCTAssertNil(session.value(for: second))
        XCTAssertFalse(session.store("late first secret", for: first))
        XCTAssertTrue(session.store("second secret", for: second))
        XCTAssertEqual(session.value(for: second), "second secret")
    }

    func testClipboardUsesLocalOnlyOptionsAndExpiresAfterThirtySeconds() {
        let fixture = ClipboardFixture()

        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)

        XCTAssertEqual(fixture.pasteboard.value, "secret")
        XCTAssertEqual(fixture.scheduler.intervals, [30])
        #if os(macOS)
        XCTAssertEqual(fixture.pasteboard.options, [.currentHostOnly])
        #endif

        fixture.clock.advance(by: 29_000_000_000)
        fixture.scheduler.fire(0)
        XCTAssertEqual(fixture.scheduler.intervals.count, 2)
        XCTAssertEqual(fixture.scheduler.cancellations, [true, false])
        XCTAssertEqual(fixture.pasteboard.value, "secret")
        XCTAssertEqual(fixture.scheduler.intervals, [30, 1])

        fixture.clock.advance(by: 1_000_000_000)
        fixture.scheduler.fire(1)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
        XCTAssertNil(fixture.pasteboard.value)
    }

    func testClipboardExpirationPreservesReplacementContents() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.pasteboard.replace(with: "public address")
        fixture.clock.advance(by: 30_000_000_000)

        fixture.scheduler.fire(0)
        XCTAssertTrue(fixture.pasteboard.readCount > 0)

        XCTAssertEqual(fixture.pasteboard.value, "public address")
        XCTAssertEqual(fixture.pasteboard.clearCount, 0)
    }

    func testWallClockRollbackCannotExtendManagedClipboardExpiration() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.clock.setDate(fixture.clock.date.addingTimeInterval(-3_600))
        fixture.clock.advance(by: 30_000_000_000)

        fixture.scheduler.fire(0)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)

        XCTAssertNil(fixture.pasteboard.value)
        XCTAssertEqual(fixture.scheduler.intervals, [30])
    }

    func testRepeatedCopiesRetireOldTimerAndUseNewDeadline() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("first secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.clock.advance(by: 10_000_000_000)
        fixture.clipboard.copy("second secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 2)
        XCTAssertEqual(fixture.scheduler.cancellations, [true, false])

        fixture.clock.advance(by: 20_000_000_000)
        fixture.scheduler.fire(0, evenIfCancelled: true)

        XCTAssertEqual(fixture.pasteboard.value, "second secret")
        XCTAssertEqual(fixture.pasteboard.clearCount, 0)
        XCTAssertEqual(fixture.scheduler.intervals.count, 2)
        XCTAssertEqual(fixture.scheduler.cancellations, [true, false])
        fixture.scheduler.fire(1)
        XCTAssertEqual(fixture.scheduler.intervals.count, 3)
        XCTAssertEqual(fixture.scheduler.intervals, [30, 30, 10])

        fixture.clock.advance(by: 10_000_000_000)
        fixture.scheduler.fire(2)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
        XCTAssertNil(fixture.pasteboard.value)
    }

    func testReleasingClipboardCancelsTimerAndRejectsItsLateCallback() {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
        let scheduler = ClipboardScheduler()
        let pasteboard = ClipboardPasteboard()
        var clipboard: SecretClipboard? = SecretClipboard(
            pasteboard: pasteboard.adapter,
            now: { clock.date },
            monotonicNow: { clock.instant },
            schedule: { scheduler.schedule($0, callback: $1) }
        )
        clipboard?.copy("secret")
        XCTAssertEqual(scheduler.cancellations, [false])

        clipboard = nil

        XCTAssertEqual(scheduler.cancellations, [true])
        pasteboard.replace(with: "replacement")
        clock.advance(by: 30_000_000_000)
        scheduler.fire(0, evenIfCancelled: true)
        XCTAssertEqual(pasteboard.value, "replacement")
        XCTAssertEqual(pasteboard.clearCount, 0)
    }

    #if os(macOS)
    func testManagedClipboardExpiresWhileTaskIsInsideAppKitModalLoop() async throws {
        let observation = await Task { @MainActor in
            ClipboardModalProbe(replacesClipboard: false).run()
        }.value
        let observed = try XCTUnwrap(observation)

        XCTAssertTrue(observed.isModalRunning)
        XCTAssertNil(observed.value)
        XCTAssertEqual(observed.clearCount, 1)
        XCTAssertGreaterThan(observed.ownershipChecks, 0)
    }

    func testManagedClipboardPreservesReplacementInsideAppKitModalLoop() async throws {
        let observation = await Task { @MainActor in
            ClipboardModalProbe(replacesClipboard: true).run()
        }.value
        let observed = try XCTUnwrap(observation)

        XCTAssertTrue(observed.isModalRunning)
        XCTAssertEqual(observed.value, "replacement")
        XCTAssertEqual(observed.clearCount, 0)
        XCTAssertGreaterThan(observed.ownershipChecks, 0)
    }

    func testClipboardUsesOwnershipReturnedByPrepareRatherThanLaterChangeCount() {
        let fixture = ClipboardFixture()
        fixture.pasteboard.replacementDuringWrite = "another application's text"
        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.clock.advance(by: 30_000_000_000)

        fixture.scheduler.fire(0)
        XCTAssertTrue(fixture.pasteboard.readCount > 0)

        XCTAssertEqual(fixture.pasteboard.value, "another application's text")
        XCTAssertEqual(fixture.pasteboard.clearCount, 0)
    }

    func testFailedClipboardWriteDoesNotScheduleCleanupForAnotherOwner() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("first secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.pasteboard.writeSucceeds = false
        fixture.pasteboard.replacementDuringWrite = "replacement"

        fixture.clipboard.copy("second secret")
        XCTAssertEqual(fixture.scheduler.cancellations, [true])
        fixture.clock.advance(by: 30_000_000_000)
        fixture.scheduler.fire(0, evenIfCancelled: true)

        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        XCTAssertEqual(fixture.pasteboard.value, "replacement")
        XCTAssertEqual(fixture.pasteboard.clearCount, 0)
    }

    func testWakeClearsOverdueSecretAndRetiresScheduledTimer() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.clock.advance(by: 31_000_000_000)

        fixture.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertNil(fixture.pasteboard.value)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
        XCTAssertEqual(fixture.scheduler.cancellations, [true])
        fixture.pasteboard.replace(with: "replacement")
        fixture.scheduler.fire(0, evenIfCancelled: true)
        XCTAssertEqual(fixture.pasteboard.value, "replacement")
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
    }

    func testWakeReschedulesRemainingTimeWithoutClearingNewContents() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)
        fixture.clock.advance(by: 20_000_000_000)

        fixture.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(fixture.scheduler.intervals.count, 2)
        XCTAssertEqual(fixture.scheduler.intervals, [30, 10])
        XCTAssertEqual(fixture.scheduler.cancellations, [true, false])
        XCTAssertEqual(fixture.pasteboard.value, "secret")

        fixture.pasteboard.replace(with: "replacement")
        fixture.clock.advance(by: 11_000_000_000)
        fixture.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(fixture.pasteboard.value, "replacement")
        XCTAssertEqual(fixture.pasteboard.clearCount, 0)
        XCTAssertEqual(fixture.scheduler.cancellations, [true, true])
    }
    #endif

    func testTerminationClearsOnlyOwnedSecret() {
        for replaceBeforeTermination in [false, true] {
            let fixture = ClipboardFixture()
            fixture.clipboard.copy("secret")
            XCTAssertEqual(fixture.scheduler.intervals.count, 1)
            if replaceBeforeTermination {
                fixture.pasteboard.replace(with: "replacement")
            }

            fixture.applicationNotifications.post(name: terminationNotification, object: nil)

            XCTAssertEqual(fixture.pasteboard.value, replaceBeforeTermination ? "replacement" : nil)
            XCTAssertEqual(fixture.pasteboard.clearCount, replaceBeforeTermination ? 0 : 1)
            XCTAssertEqual(fixture.scheduler.cancellations, [true])
            fixture.pasteboard.replace(with: "later replacement")
            fixture.clock.advance(by: 30_000_000_000)
            fixture.scheduler.fire(0, evenIfCancelled: true)
            XCTAssertEqual(fixture.pasteboard.value, "later replacement")
        }
    }

    func testAppDeactivationLeavesClipboardTimerRunning() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("secret")
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)

        fixture.applicationNotifications.post(name: deactivationNotification, object: nil)

        XCTAssertEqual(fixture.pasteboard.value, "secret")
        XCTAssertEqual(fixture.scheduler.cancellations, [false])
        fixture.clock.advance(by: 30_000_000_000)
        fixture.scheduler.fire(0)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
        XCTAssertNil(fixture.pasteboard.value)
    }

    func testPresentationInvalidationDoesNotCancelClipboardExpiration() {
        let fixture = ClipboardFixture()
        let session = SecretPresentationSession()
        let token = session.begin()
        session.store("secret", for: token)
        fixture.clipboard.copy(session.value(for: token)!)
        XCTAssertEqual(fixture.scheduler.intervals.count, 1)

        session.invalidate()

        XCTAssertNil(session.value(for: token))
        XCTAssertEqual(fixture.pasteboard.value, "secret")
        XCTAssertEqual(fixture.scheduler.cancellations, [false])
        fixture.clock.advance(by: 30_000_000_000)
        fixture.scheduler.fire(0)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
        XCTAssertNil(fixture.pasteboard.value)
    }

    func testSystemManagedClipboardNeverSchedulesOrManuallyClearsContents() {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
        let notifications = NotificationCenter()
        var value: String?
        var deadline: Date?
        var writes = 0
        var schedules = 0
        let clipboard = SecretClipboard(
            pasteboard: .systemManaged { secret, expiresAt in
                value = secret
                deadline = expiresAt
                writes += 1
            },
            now: { clock.date },
            schedule: { _, _ in
                schedules += 1
                return {}
            },
            applicationNotifications: notifications,
            workspaceNotifications: notifications
        )
        clipboard.copy("secret")
        XCTAssertEqual(value, "secret")
        XCTAssertEqual(deadline, clock.date.addingTimeInterval(30))
        value = "another application's text"
        clock.advance(by: 31_000_000_000)

        notifications.post(name: activationNotification, object: nil)
        notifications.post(name: terminationNotification, object: nil)
        #if os(macOS)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #endif

        XCTAssertEqual(value, "another application's text")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(schedules, 0)
    }

    #if !os(macOS)
    func testUIKitAdapterWritesLocalOnlySystemExpirationWithoutAdoptingReplacement() {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
        let notifications = NotificationCenter()
        var items = [[String: Any]]()
        var options = [UIPasteboard.OptionsKey: Any]()
        var schedules = 0
        let clipboard = SecretClipboard(
            pasteboard: .uiKit { writtenItems, writtenOptions in
                items = writtenItems
                options = writtenOptions
            },
            now: { clock.date },
            schedule: { _, _ in
                schedules += 1
                return {}
            },
            applicationNotifications: notifications
        )

        clipboard.copy("secret")

        XCTAssertEqual(items.first?[UIPasteboard.typeAutomatic] as? String, "secret")
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(options[.expirationDate] as? Date, clock.date.addingTimeInterval(30))
        items = [[UIPasteboard.typeAutomatic: "replacement"]]
        clock.advance(by: 31_000_000_000)
        notifications.post(name: activationNotification, object: nil)
        notifications.post(name: terminationNotification, object: nil)
        XCTAssertEqual(items.first?[UIPasteboard.typeAutomatic] as? String, "replacement")
        XCTAssertEqual(schedules, 0)
    }
    #endif

    func testActivationRechecksOverdueClipboardWithoutWaitingForTimer() {
        let fixture = ClipboardFixture()
        fixture.clipboard.copy("secret")
        fixture.clock.advance(by: 31_000_000_000)

        fixture.applicationNotifications.post(name: activationNotification, object: nil)

        XCTAssertNil(fixture.pasteboard.value)
        XCTAssertEqual(fixture.pasteboard.clearCount, 1)
    }

    private var terminationNotification: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willTerminateNotification
        #endif
    }

    private var activationNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    private var deactivationNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didResignActiveNotification
        #else
        UIApplication.didEnterBackgroundNotification
        #endif
    }
}

#if os(macOS)
@MainActor
private final class ClipboardModalProbe: NSObject {
    struct Observation {
        let isModalRunning: Bool
        let value: String?
        let clearCount: Int
        let ownershipChecks: Int
    }

    private let pasteboard = ClipboardPasteboard()
    private let instant = ContinuousClock().now
    private let alert = NSAlert()
    private let replacesClipboard: Bool
    private var clockReads = 0
    private var observation: Observation?

    init(replacesClipboard: Bool) {
        self.replacesClipboard = replacesClipboard
    }

    func run() -> Observation? {
        let application = NSApplication.shared
        let previousKeyWindow = application.keyWindow
        let owner = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        owner.isReleasedWhenClosed = false
        owner.alphaValue = 0
        owner.orderFront(nil)
        alert.messageText = "Disposable clipboard expiration test"
        alert.addButton(withTitle: "OK")
        alert.window.alphaValue = 0
        alert.window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))

        let clipboard = SecretClipboard(
            pasteboard: pasteboard.adapter,
            monotonicNow: { [self] in
                clockReads += 1
                return instant.advanced(by: .milliseconds(
                    clockReads == 1 ? 0 : clockReads == 2 ? 29_900 : 31_000
                ))
            }
        )
        var timers = [
            Timer(timeInterval: 0.3, target: self, selector: #selector(observe(_:)), userInfo: nil, repeats: false),
            Timer(timeInterval: 0.5, target: self, selector: #selector(closeModal(_:)), userInfo: nil, repeats: false),
        ]
        if replacesClipboard {
            timers.append(Timer(
                timeInterval: 0.05, target: self, selector: #selector(replaceClipboard(_:)), userInfo: nil, repeats: false
            ))
        }
        defer {
            timers.forEach { $0.invalidate() }
            alert.window.orderOut(nil)
            owner.close()
            previousKeyWindow?.makeKey()
        }
        clipboard.copy("disposable secret")
        timers.forEach { RunLoop.main.add($0, forMode: .modalPanel) }
        withExtendedLifetime(clipboard) {
            _ = alert.runModal()
        }
        return observation
    }

    @objc private func replaceClipboard(_ timer: Timer) {
        pasteboard.replace(with: "replacement")
    }

    @objc private func observe(_ timer: Timer) {
        observation = Observation(
            isModalRunning: NSApplication.shared.modalWindow === alert.window,
            value: pasteboard.value,
            clearCount: pasteboard.clearCount,
            ownershipChecks: pasteboard.readCount
        )
    }

    @objc private func closeModal(_ timer: Timer) {
        alert.buttons[0].performClick(nil)
    }
}
#endif

@MainActor
private final class ClipboardFixture {
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
    let scheduler = ClipboardScheduler()
    let pasteboard = ClipboardPasteboard()
    let applicationNotifications = NotificationCenter()
    let workspaceNotifications = NotificationCenter()
    let clipboard: SecretClipboard

    init() {
        clipboard = SecretClipboard(
            pasteboard: pasteboard.adapter,
            now: { [clock] in clock.date },
            monotonicNow: { [clock] in clock.instant },
            schedule: { [scheduler] in scheduler.schedule($0, callback: $1) },
            applicationNotifications: applicationNotifications,
            workspaceNotifications: workspaceNotifications
        )
    }
}

@MainActor
private final class ClipboardScheduler {
    private(set) var intervals = [TimeInterval]()
    private(set) var cancellations = [Bool]()
    private var callbacks = [@MainActor () -> Void]()

    func schedule(_ interval: Duration, callback: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let components = interval.components
        intervals.append(Double(components.seconds) + Double(components.attoseconds) / 1e18)
        let index = callbacks.count
        callbacks.append(callback)
        cancellations.append(false)
        return { [weak self] in self?.cancellations[index] = true }
    }

    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        guard evenIfCancelled || !cancellations[index] else { return }
        callbacks[index]()
    }
}

@MainActor
private final class ClipboardPasteboard {
    var value: String?
    var writeSucceeds = true
    var replacementDuringWrite: String?
    private var ownership = 0
    private(set) var clearCount = 0
    private(set) var readCount = 0
    #if os(macOS)
    private(set) var options = [NSPasteboard.ContentsOptions]()
    #endif

    var adapter: SecretClipboard.Pasteboard {
        #if os(macOS)
        .macOS(
            prepare: { [self] options in
                self.options.append(options)
                ownership += 1
                value = nil
                return ownership
            },
            setString: { [self] secret in
                if writeSucceeds { value = secret }
                if let replacementDuringWrite { replace(with: replacementDuringWrite) }
                return writeSucceeds
            },
            changeCount: { [self] in
                readCount += 1
                return ownership
            },
            clear: { [self] in clear() }
        )
        #else
        .applicationManaged(
            write: { [self] secret in
                value = secret
                ownership += 1
                return ownership
            },
            changeCount: { [self] in
                readCount += 1
                return ownership
            },
            clear: { [self] in clear() }
        )
        #endif
    }

    func replace(with text: String) {
        value = text
        ownership += 1
    }

    private func clear() {
        value = nil
        ownership += 1
        clearCount += 1
    }
}

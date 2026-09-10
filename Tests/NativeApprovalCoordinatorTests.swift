// ∅ 2026 lil org

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeApprovalCoordinatorTests: XCTestCase {

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class StageGate {
        var continuation: CheckedContinuation<
            ExtensionBridge.StoreMutationResult,
            Never
        >?
        var pendingResult: ExtensionBridge.StoreMutationResult?

        func run() async -> ExtensionBridge.StoreMutationResult {
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(_ result: ExtensionBridge.StoreMutationResult) {
            let continuation = continuation
            self.continuation = nil
            if let continuation {
                continuation.resume(returning: result)
            } else {
                pendingResult = result
            }
        }
    }

    private final class CoordinatorStore: NativeDeliveryStore {
        var loadHandler: (ExtensionBridge.Handle) async ->
            ExtensionBridge.SnapshotResult = { _ in .missing }
        var recordHandler: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryNonce,
            UUID
        ) async -> ExtensionBridge.StoreMutationResult = { _, _, _ in
            .ownershipLost
        }
        var stageHandler: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryNonce,
            UUID,
            NativeApprovalDecision
        ) async -> ExtensionBridge.StoreMutationResult = { _, _, _, _ in
            .ownershipLost
        }
        var completeHandler: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryNonce,
            UUID,
            ResponseToExtension
        ) async -> ExtensionBridge.StoreMutationResult = { _, _, _, _ in
            .ownershipLost
        }
        var rejectHandler: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryNonce,
            UUID
        ) async -> ExtensionBridge.StoreMutationResult = { _, _, _ in
            .ownershipLost
        }

        func load(
            handle: ExtensionBridge.Handle
        ) async -> ExtensionBridge.SnapshotResult {
            await loadHandler(handle)
        }

        func recordNativeDeliveryReceipt(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) async -> ExtensionBridge.StoreMutationResult {
            await recordHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier
            )
        }

        func stageNativeDecision(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID,
            decision: NativeApprovalDecision
        ) async -> ExtensionBridge.StoreMutationResult {
            await stageHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier,
                decision
            )
        }

        func completeNativeDelivery(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID,
            response: ResponseToExtension
        ) async -> ExtensionBridge.StoreMutationResult {
            await completeHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier,
                response
            )
        }

        func rejectNativeDelivery(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) async -> ExtensionBridge.StoreMutationResult {
            await rejectHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier
            )
        }
    }

    private final class TrackingMenu: NSMenu {
        private(set) var cancellationCount = 0

        override func cancelTrackingWithoutAnimation() {
            cancellationCount += 1
        }
    }

    private final class TrackingWindow: NSWindow {
        private(set) var activationCount = 0
        private(set) var deminiaturizationCount = 0

        override func deminiaturize(_ sender: Any?) {
            deminiaturizationCount += 1
            super.deminiaturize(sender)
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            activationCount += 1
            super.makeKeyAndOrderFront(sender)
        }

        func resetActivationCount() {
            activationCount = 0
        }
    }

    func testInitialAuthenticationFailureFallsBackOnlyOnStart() {
        XCTAssertEqual(
            Agent.localAuthenticationResolution(success: true, onStart: true),
            .authenticated
        )
        XCTAssertEqual(
            Agent.localAuthenticationResolution(success: false, onStart: true),
            .showPassword
        )
        XCTAssertEqual(
            Agent.localAuthenticationResolution(success: false, onStart: false),
            .failed
        )
    }

    func testAuthenticationPresentationRestoresOnlyItsCurrentWindow() {
        let window = TrackingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = NSViewController()
        controller.view = NSView(frame: window.contentView!.bounds)
        window.contentViewController = controller
        let presentation = Agent.WeakViewControllerReference()
        presentation.value = controller

        presentation.reactivateWindow()

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertEqual(window.activationCount, 1)
        XCTAssertEqual(window.deminiaturizationCount, 1)

        window.orderOut(nil)
        presentation.value = nil
        presentation.reactivateWindow()
        XCTAssertFalse(window.isVisible)

        presentation.value = controller
        window.contentViewController = NSViewController()
        presentation.reactivateWindow()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.activationCount, 1)
        XCTAssertEqual(window.deminiaturizationCount, 1)
    }

    func testPendingWalletOpenIntentIsConsumedOnce() {
        var intent = PendingWalletOpenIntent()
        intent.record()
        intent.record()

        XCTAssertTrue(intent.consume())
        XCTAssertFalse(intent.consume())

        var fallback = PendingWalletOpenIntent()
        XCTAssertFalse(fallback.consume())
        fallback.record()
        fallback.cancel()
        XCTAssertFalse(fallback.consume())
    }

    func testDockOnboardingHandoffDeduplicatesAndCommitsOnlySuccess() {
        var handoff = DockOnboardingHandoff()
        var intent = PendingWalletOpenIntent()
        intent.record()

        XCTAssertTrue(handoff.begin())
        XCTAssertFalse(handoff.begin())
        if handoff.finish(succeeded: false) {
            intent.cancel()
        }
        XCTAssertTrue(intent.isPending)
        XCTAssertFalse(handoff.isInFlight)

        XCTAssertTrue(handoff.begin())
        if handoff.finish(succeeded: true) {
            intent.cancel()
        }
        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(handoff.finish(succeeded: true))
    }

    func testDockOnboardingResolvesAppContainingSafariExtensionHelper() {
        let appURL = URL(
            fileURLWithPath: "/Users/test/Build/Products/Debug/Renamed Wallet.app",
            isDirectory: true
        )
        let helperURL = appURL.appendingPathComponent(
            "Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app",
            isDirectory: true
        )

        XCTAssertEqual(
            DockAppLauncher.enclosingAppURL(forHelperAt: helperURL),
            appURL
        )
    }

    func testDockOnboardingRejectsHelpersOutsideExpectedBundleStructure() {
        let paths = [
            "/Applications/Big Wallet.app",
            "/Applications/Wallet.app/Contents/Helpers/Big Wallet.app",
            "/Applications/Wallet.app/Contents/PlugIns/Safari.appex/Contents/Resources/Big Wallet.app",
            "/Applications/Wallet.app/Contents/PlugIns/Safari.app/Contents/Helpers/Big Wallet.app",
            "/Applications/Wallet.app/Contents/Resources/Safari.appex/Contents/Helpers/Big Wallet.app",
            "/Applications/Wallet.app/Resources/PlugIns/Safari.appex/Contents/Helpers/Big Wallet.app",
            "/Applications/Wallet/Contents/PlugIns/Safari.appex/Contents/Helpers/Big Wallet.app",
            "/Applications/Wallet.app/Contents/PlugIns/Safari.appex/Contents/Helpers/Other.app",
        ]

        for path in paths {
            XCTAssertNil(
                DockAppLauncher.enclosingAppURL(
                    forHelperAt: URL(fileURLWithPath: path, isDirectory: true)
                ),
                path
            )
        }
        XCTAssertNil(DockAppLauncher.enclosingAppURL(
            forHelperAt: URL(string:
                "https://example.com/Wallet.app/Contents/PlugIns/Safari.appex/Contents/Helpers/Big%20Wallet.app"
            )!
        ))
    }

    func testApprovalInboxCancellationIncludesInFlightValidation() {
        var inbox = ApprovalInbox<String>()
        let first = approvalKey(id: 100)
        let second = approvalKey(id: 101)

        XCTAssertTrue(inbox.register(first))
        XCTAssertEqual(inbox.takeUnstartedValidations(), [first])
        XCTAssertTrue(inbox.register(second))

        XCTAssertEqual(
            Set(inbox.markPendingAsCanceling().map(\.key)),
            Set([first, second])
        )
        XCTAssertTrue(inbox.isCanceling(first))
        XCTAssertTrue(inbox.isCanceling(second))
        XCTAssertFalse(inbox.beginReceiptAcquisition(
            first,
            order: approvalOrder(id: 100)
        ))
    }

    func testApprovalInboxSupportsSequentialCancellationsWithoutFixedFence() {
        var inbox = ApprovalInbox<String>()

        for id in 0..<32 {
            let key = approvalKey(id: id)
            XCTAssertTrue(inbox.register(key))
            XCTAssertEqual(
                inbox.markPendingAsCanceling(),
                [.init(key: key, receiptOwned: false)]
            )
            XCTAssertTrue(inbox.isCanceling(key))
            inbox.remove(key)
        }

        XCTAssertEqual(inbox.count, 0)
    }

    func testApprovalInboxDoesNotApplyProfileCapacityGlobally() {
        var inbox = ApprovalInbox<String>()

        for id in 0..<24 {
            let key = approvalKey(
                id: id,
                profileIdentifier: UUID()
            )
            XCTAssertTrue(inbox.register(key))
            XCTAssertTrue(inbox.beginReceiptAcquisition(
                key,
                order: approvalOrder(id: id)
            ))
            XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
            XCTAssertTrue(inbox.activate("active-\(id)", for: key))
        }

        XCTAssertEqual(inbox.count, 24)
    }

    func testApprovalInboxBoundsOnlyUnverifiedRoutes() {
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 2)
        let first = approvalKey(id: 200)
        let second = approvalKey(id: 201)
        let third = approvalKey(id: 202)

        XCTAssertTrue(inbox.register(first))
        XCTAssertTrue(inbox.register(second))
        XCTAssertFalse(inbox.register(third))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            first,
            order: approvalOrder(id: 200)
        ))
        XCTAssertFalse(inbox.register(third))
        XCTAssertEqual(inbox.receiptAcquired(first), .awaitAuthentication)
        XCTAssertTrue(inbox.register(third))
    }

    func testApprovalInboxWaitsForReceiptBeforeAuthentication() {
        var inbox = ApprovalInbox<String>()
        let key = approvalKey(id: 203)

        XCTAssertTrue(inbox.register(key))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            key,
            order: approvalOrder(id: 203)
        ))
        XCTAssertTrue(inbox.isAcquiringReceipt(key))
        XCTAssertFalse(inbox.hasAwaitingAuthentication)

        XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
        XCTAssertTrue(inbox.hasAwaitingAuthentication)
        XCTAssertTrue(inbox.isAwaitingAuthentication(key))
    }

    func testApprovalInboxCancellationAfterReceiptUsesExactOwner() {
        var inbox = ApprovalInbox<String>()
        let key = approvalKey(id: 204)
        XCTAssertTrue(inbox.register(key))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            key,
            order: approvalOrder(id: 204)
        ))
        XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)

        XCTAssertEqual(
            inbox.markPendingAsCanceling(),
            [.init(key: key, receiptOwned: true)]
        )
        XCTAssertTrue(inbox.isCanceling(key))
    }

    func testApprovalInboxCancellationDuringReceiptAcquisitionWaitsForOutcome() {
        var inbox = ApprovalInbox<String>()
        let key = approvalKey(id: 205)
        XCTAssertTrue(inbox.register(key))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            key,
            order: approvalOrder(id: 205)
        ))

        XCTAssertTrue(inbox.markPendingAsCanceling().isEmpty)
        XCTAssertEqual(inbox.receiptAcquired(key), .cancel)
        XCTAssertTrue(inbox.isCanceling(key))
    }

    func testReceiptOwnedStagedCancellationRetainsExactReceiptForRetry() throws {
        let handle = makeHandle(id: 206)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let key = ApprovalRouteKey(
            handle: handle,
            nativeDeliveryNonce: nonce
        )
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime
        )
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        let staged = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: deadline,
            receipt: receipt,
            nativeDecisionStaged: true
        )
        let unstaged = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: deadline,
            receipt: receipt
        )
        let executing = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: deadline,
            receipt: receipt,
            phase: .approving,
            nativeDecisionStaged: true
        )

        XCTAssertEqual(Agent.receiptOwnedCancellationAction(
            snapshot: staged,
            key: key,
            runtimeInstanceIdentifier: runtime
        ), .retainForAuthenticationRetry)
        XCTAssertEqual(Agent.receiptOwnedCancellationAction(
            snapshot: unstaged,
            key: key,
            runtimeInstanceIdentifier: runtime
        ), .reject)
        XCTAssertEqual(Agent.receiptOwnedCancellationAction(
            snapshot: staged,
            key: key,
            runtimeInstanceIdentifier: UUID()
        ), .finish)
        XCTAssertEqual(Agent.receiptOwnedCancellationAction(
            snapshot: executing,
            key: key,
            runtimeInstanceIdentifier: runtime
        ), .finish)
    }

    func testApprovalInboxRestoresSameRuntimeAuthenticationRetry() {
        var inbox = ApprovalInbox<String>()
        let key = approvalKey(id: 207)

        XCTAssertTrue(inbox.register(key))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            key,
            order: approvalOrder(id: 207)
        ))
        XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
        XCTAssertEqual(
            inbox.markPendingAsCanceling(),
            [.init(key: key, receiptOwned: true)]
        )

        XCTAssertTrue(inbox.restoreAwaitingAuthentication(key))
        XCTAssertTrue(inbox.isAwaitingAuthentication(key))
        XCTAssertFalse(inbox.register(key))
        XCTAssertFalse(inbox.restoreAwaitingAuthentication(key))
    }

    func testApprovalInboxPreservesActiveDeduplication() {
        var inbox = ApprovalInbox<String>()
        let key = approvalKey(id: 102)

        XCTAssertTrue(inbox.register(key))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            key,
            order: approvalOrder(id: 102)
        ))
        XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
        XCTAssertTrue(inbox.activate("active", for: key))
        XCTAssertFalse(inbox.register(key))
        XCTAssertEqual(inbox.active(for: key), "active")
    }

    func testWalletIntentIsIndependentFromApprovalInboxCapacity() {
        var inbox = ApprovalInbox<String>()
        var intent = PendingWalletOpenIntent()
        intent.record()

        for id in 0..<32 {
            let key = approvalKey(id: id)
            XCTAssertTrue(inbox.register(key))
            XCTAssertTrue(inbox.beginReceiptAcquisition(
                key,
                order: approvalOrder(id: id)
            ))
            XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
            XCTAssertTrue(inbox.activate("active-\(id)", for: key))
        }

        XCTAssertEqual(inbox.count, 32)
        XCTAssertTrue(intent.consume())
    }

    func testApprovalInboxOrdersAuthenticationBySnapshotAge() {
        var inbox = ApprovalInbox<String>()
        let newer = approvalKey(id: 301)
        let older = approvalKey(id: 300)

        XCTAssertTrue(inbox.register(newer))
        XCTAssertTrue(inbox.register(older))
        XCTAssertEqual(inbox.takeUnstartedValidations(), [newer, older])
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            newer,
            order: approvalOrder(id: 301)
        ))
        XCTAssertEqual(inbox.receiptAcquired(newer), .awaitAuthentication)
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            older,
            order: approvalOrder(id: 300)
        ))
        XCTAssertEqual(inbox.receiptAcquired(older), .awaitAuthentication)

        XCTAssertEqual(inbox.awaitingAuthenticationKeys, [older, newer])
        XCTAssertTrue(inbox.activate("newer", for: newer))
        XCTAssertTrue(inbox.activate("older", for: older))
        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, older)
    }

    func testApprovalInboxBreaksSnapshotTiesDeterministically() {
        var inbox = ApprovalInbox<String>()
        let higherSequence = approvalKey(id: 310)
        let firstTie = approvalKey(id: 311)
        let secondTie = approvalKey(id: 312)
        let timestamp = Date(timeIntervalSince1970: 100)

        for key in [higherSequence, firstTie, secondTie] {
            XCTAssertTrue(inbox.register(key))
        }
        XCTAssertEqual(
            inbox.takeUnstartedValidations(),
            [higherSequence, firstTie, secondTie]
        )
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            higherSequence,
            order: .init(createdAt: timestamp, sequence: 2)
        ))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            firstTie,
            order: .init(createdAt: timestamp, sequence: 1)
        ))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            secondTie,
            order: .init(createdAt: timestamp, sequence: 1)
        ))
        for key in [higherSequence, firstTie, secondTie] {
            XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
        }

        XCTAssertEqual(
            inbox.awaitingAuthenticationKeys,
            [firstTie, secondTie, higherSequence]
        )
    }

    func testApprovalInboxOrderingIsStableWithValidationInProgress() {
        var inbox = ApprovalInbox<String>()
        let newer = approvalKey(id: 313)
        let validating = approvalKey(id: 314)
        let older = approvalKey(id: 315)

        for key in [newer, validating, older] {
            XCTAssertTrue(inbox.register(key))
        }
        XCTAssertEqual(
            inbox.takeUnstartedValidations(),
            [newer, validating, older]
        )
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            newer,
            order: .init(
                createdAt: Date(timeIntervalSince1970: 200),
                sequence: 0
            )
        ))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            older,
            order: .init(
                createdAt: Date(timeIntervalSince1970: 100),
                sequence: 0
            )
        ))
        XCTAssertEqual(inbox.receiptAcquired(newer), .awaitAuthentication)
        XCTAssertEqual(inbox.receiptAcquired(older), .awaitAuthentication)

        XCTAssertEqual(inbox.awaitingAuthenticationKeys, [older, newer])
        XCTAssertTrue(inbox.activate("newer", for: newer))
        XCTAssertTrue(inbox.activate("older", for: older))
        XCTAssertEqual(
            inbox.oldestActive(where: { _ in true })?.key,
            older
        )
    }

    func testApprovalInboxRemovalPromotesNextOldestActiveApproval() {
        var inbox = ApprovalInbox<String>()
        let older = approvalKey(id: 320)
        let newer = approvalKey(id: 321)

        for (key, id) in [(newer, 321), (older, 320)] {
            XCTAssertTrue(inbox.register(key))
            XCTAssertTrue(inbox.beginReceiptAcquisition(
                key,
                order: approvalOrder(id: id)
            ))
            XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
            XCTAssertTrue(inbox.activate("active-\(id)", for: key))
        }

        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, older)
        inbox.remove(older)
        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, newer)
    }

    func testApprovalInboxCancellationRemainsInRegistrationOrder() {
        var inbox = ApprovalInbox<String>()
        let first = approvalKey(id: 331)
        let second = approvalKey(id: 330)

        XCTAssertTrue(inbox.register(first))
        XCTAssertTrue(inbox.register(second))
        _ = inbox.takeUnstartedValidations()
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            first,
            order: approvalOrder(id: 331)
        ))
        XCTAssertTrue(inbox.beginReceiptAcquisition(
            second,
            order: approvalOrder(id: 330)
        ))
        XCTAssertEqual(inbox.receiptAcquired(first), .awaitAuthentication)
        XCTAssertEqual(inbox.receiptAcquired(second), .awaitAuthentication)

        XCTAssertEqual(
            inbox.markPendingAsCanceling().map(\.key),
            [first, second]
        )
    }

    func testOldestApprovalWindowCanBeFrontmostWithoutClosingNewer() throws {
        var inbox = ApprovalInbox<WalletWindowController>()
        let olderKey = approvalKey(id: 340)
        let newerKey = approvalKey(id: 341)
        let olderWindow = TrackingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let newerWindow = TrackingWindow(
            contentRect: NSRect(x: -9_700, y: -10_000, width: 320, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        olderWindow.contentViewController = NSViewController()
        newerWindow.contentViewController = NSViewController()
        let older = WalletWindowController(window: olderWindow)
        let newer = WalletWindowController(window: newerWindow)
        older.showWindow(nil)
        newer.showWindow(nil)
        defer {
            olderWindow.close()
            newerWindow.close()
        }
        olderWindow.resetActivationCount()
        newerWindow.resetActivationCount()

        for (key, id, controller) in [
            (newerKey, 341, newer),
            (olderKey, 340, older),
        ] {
            XCTAssertTrue(inbox.register(key))
            XCTAssertTrue(inbox.beginReceiptAcquisition(
                key,
                order: .init(
                    createdAt: Date(
                        timeIntervalSince1970: TimeInterval(id)
                    ),
                    sequence: 0
                )
            ))
            XCTAssertEqual(inbox.receiptAcquired(key), .awaitAuthentication)
            XCTAssertTrue(inbox.activate(controller, for: key))
        }
        let selected = try XCTUnwrap(inbox.oldestActive { approval in
            guard let window = approval.window else { return false }
            return Window.isVisibleContentWindow(window)
        })

        Window.reactivateWindow(selected.value)

        XCTAssertEqual(selected.key, olderKey)
        XCTAssertGreaterThan(olderWindow.activationCount, 0)
        XCTAssertEqual(newerWindow.activationCount, 0)
        XCTAssertTrue(newerWindow.isVisible)
    }

    func testAmbientMissingPasswordRejectsApprovalBeforeOnboarding() {
        XCTAssertEqual(
            Agent.missingPasswordApprovalAction(canCreatePassword: false),
            .rejectAndOpenDock
        )
        XCTAssertEqual(
            Agent.missingPasswordApprovalAction(canCreatePassword: true),
            .awaitOnboarding
        )
    }

    func testFinishedApprovalAlwaysClosesExistingWindow() {
        XCTAssertEqual(Agent.finishedApprovalWindowAction(
            windowNumber: nil,
            isVisible: true,
            isMiniaturized: false
        ), .none)
        XCTAssertEqual(Agent.finishedApprovalWindowAction(
            windowNumber: 42,
            isVisible: false,
            isMiniaturized: false
        ), .close)
        XCTAssertEqual(Agent.finishedApprovalWindowAction(
            windowNumber: 42,
            isVisible: true,
            isMiniaturized: false
        ), .closeAndActivate)
        XCTAssertEqual(Agent.finishedApprovalWindowAction(
            windowNumber: 42,
            isVisible: false,
            isMiniaturized: true
        ), .closeAndActivate)
    }

    func testTransactionApprovalDescriptionPreservesMainSummary() throws {
        let destination = "0x1234567890abcdef1234567890abcdef12345678"
        let chain = try XCTUnwrap(Networks.ethereum)
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: destination,
            value: "0xde0b6b3a7640000",
            data: "0x"
        )

        let description = ApproveTransactionViewController.approvalDescription(
            transaction: transaction,
            chain: chain,
            price: nil
        )

        XCTAssertTrue(description.hasPrefix("🌐 \(chain.name)\n\n1 ETH"))
        XCTAssertTrue(description.contains("\(Strings.fee):"))
        XCTAssertTrue(description.contains("\(Strings.gasPrice):"))
        XCTAssertFalse(description.contains(destination))
    }

    func testTransactionApprovalDescriptionPreservesContractData() throws {
        let chain = try XCTUnwrap(Networks.ethereum)
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "",
            value: "0x0",
            data: "0x6000"
        )

        let description = ApproveTransactionViewController.approvalDescription(
            transaction: transaction,
            chain: chain,
            price: nil
        )

        XCTAssertTrue(description.contains("\(Strings.data): 0x6000"))
        XCTAssertEqual(description.components(separatedBy: "\n\n").count, 5)
    }

    func testDuplicateRouteReactivationKeepsTerminalUIClosed() {
        for state in [
            NativeApprovalCoordinator.State.loading,
            .reviewing,
            .staging,
            .staged,
        ] {
            XCTAssertTrue(Agent.shouldReactivateApproval(in: state))
        }
        XCTAssertFalse(Agent.shouldReactivateApproval(in: .rejecting))
        XCTAssertFalse(Agent.shouldReactivateApproval(in: .finished))
    }

    func testApprovalWindowContextSurvivesContentReplacement() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        XCTAssertNil(windowController.approvalPeer)

        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        windowController.contentViewController = NSViewController()
        windowController.contentViewController = NSViewController()

        XCTAssertEqual(windowController.approvalPeer?.name, "wallet.example")
    }

    func testApprovalImportPreservesMainLayout() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = instantiate(ImportViewController.self)
        windowController.contentViewController = controller
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.view.frame.size, NSSize(width: 250, height: 350))
        XCTAssertEqual(
            try titleTopSpacing(controller.titleTextField, in: controller.view),
            24
        )
        XCTAssertEqual(controller.textField.frame.size, NSSize(width: 190, height: 150))
        XCTAssertFalse(controller.view.subviews.contains {
            ($0 as? NSTextField)?.stringValue == "wallet.example"
        })
    }

    func testApprovalPasswordPreservesMainLayout() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = PasswordViewController.with(
            mode: .enter,
            reason: .approveTransaction,
            completion: nil
        )
        windowController.contentViewController = controller
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.view.frame.size, NSSize(width: 250, height: 350))
        XCTAssertEqual(
            try titleTopSpacing(controller.titleLabel, in: controller.view),
            24
        )
        XCTAssertEqual(
            controller.reasonLabel.stringValue,
            "\(Strings.to) " + AuthenticationReason.approveTransaction.title.lowercased()
        )
        XCTAssertTrue(controller.passwordTextField.stringValue.isEmpty)
        XCTAssertFalse(controller.okButton.isEnabled)
    }

    func testMessageApprovalRestoresFaviconAndNameRowWhenReplacingVisibleContent() async throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let window = try XCTUnwrap(windowController.window)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        windowController.showWindow(nil)
        defer { window.close() }
        XCTAssertTrue(window.isVisible)
        let account = WalletAccount(
            address: "0x0000000000000000000000000000000000000001",
            coin: .ethereum,
            derivation: .default,
            derivationPath: "m/44'/60'/0'/0/0",
            publicKey: "",
            extendedPublicKey: ""
        )
        let controller = ApproveViewController.with(
            subject: .signMessage,
            meta: "Review this message",
            account: account,
            walletId: "appearance-test",
            completion: { _ in XCTFail("Appearance does not approve a request") }
        )
        windowController.contentViewController = controller
        let requesterAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "stringValue == %@", "wallet.example"),
            object: controller.peerNameLabel
        )
        await fulfillment(of: [requesterAppeared], timeout: 2)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.view.window === window)
        XCTAssertEqual(controller.view.frame.size, NSSize(width: 250, height: 372))
        XCTAssertEqual(controller.peerNameLabel.stringValue, "wallet.example")
        XCTAssertTrue(
            controller.peerNameLabel.superview === controller.peerLogoImageView.superview
        )
        XCTAssertFalse(try XCTUnwrap(controller.peerNameLabel.superview).isHidden)
        XCTAssertEqual(controller.peerLogoImageView.frame.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(
            try titleTopSpacing(controller.titleLabel, in: controller.view),
            46
        )
        XCTAssertTrue(controller.metaTextView.string.hasSuffix("Review this message"))
        controller.invalidateNativeApprovalReview()
    }

    func testApprovalHostingSheetPreservesMainContentAndSize() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = NSViewController()
        controller.view = NSView()
        windowController.contentViewController = controller

        let sheet = controller.makeHostingWindow(content: EmptyView())

        XCTAssertTrue(sheet.contentView is NSHostingView<EmptyView>)
        XCTAssertEqual(
            sheet.contentRect(forFrameRect: sheet.frame).size,
            NSSize(width: 300, height: 400)
        )
    }

    func testApprovalAlertPreservesAccessoryAndParentSheet() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = NSViewController()
        controller.view = NSView()
        windowController.contentViewController = controller
        let alert = Alert()
        alert.messageText = "Review"
        alert.addButton(withTitle: Strings.ok)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        alert.accessoryView = input

        controller.presentAlert(alert) { _ in }

        XCTAssertTrue(alert.window.sheetParent === windowController.window)
        XCTAssertTrue(alert.accessoryView === input)
        XCTAssertEqual(input.frame.size, NSSize(width: 230, height: 24))
        windowController.window?.endSheet(
            alert.window,
            returnCode: .abort
        )
    }

    func testOrdinaryHostingSheetPreservesMainContentAndSize() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        let controller = NSViewController()
        controller.view = NSView()
        windowController.contentViewController = controller

        let sheet = controller.makeHostingWindow(content: EmptyView())

        XCTAssertTrue(sheet.contentView is NSHostingView<EmptyView>)
        XCTAssertEqual(
            sheet.contentRect(forFrameRect: sheet.frame).size,
            NSSize(width: 300, height: 400)
        )
    }

    func testSwitchAccountHeaderDoesNotDependOnConnectedProviders() {
        let action = SelectAccountAction(
            coinType: nil,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: nil,
            resolve: { _, _ in fatalError() }
        )
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .switchAccount,
            completion: { _, _ in }
        )

        XCTAssertEqual(
            AccountsListViewController.headerMode(accountSelection: session),
            .switchAccount
        )
    }

    func testAccountSelectionCompletionUsesSessionNetwork() throws {
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: Networks.ethereum,
            resolve: { _, _ in fatalError() }
        )
        let changedNetwork = try XCTUnwrap(Networks.withChainId(10))
        var completedNetwork: EthereumNetwork?
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .selectAccount,
            completion: { _, network in completedNetwork = network }
        )
        session.network = changedNetwork

        session.complete(accounts: [])

        XCTAssertEqual(completedNetwork, changedNetwork)
    }

    func testAccountSelectionUsesCompactNetworkButtonWithAccessibleIdentity() throws {
        let template = try XCTUnwrap(Networks.withChainId(58_008))
        let network = EthereumNetwork(
            chainId: template.chainId,
            name: "Public Goods Network Sepolia With A Very Long Custom Name",
            symbol: template.symbol,
            rpcEndpoint: template.rpcEndpoint,
            isTestnet: template.isTestnet,
            mightShowPrice: template.mightShowPrice,
            explorer: template.explorer
        )
        let identity = "\(network.chainIdHexString) · \(network.name)"
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: network,
            resolve: { _, _ in fatalError() }
        )
        let controller = instantiate(AccountsListViewController.self)
        controller.accountSelection = NativeAccountSelectionSession(
            action: action,
            mode: .selectAccount,
            completion: { _, _ in }
        )
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.networkButton.title.isEmpty)
        XCTAssertEqual(controller.networkButton.imagePosition, .imageOnly)
        XCTAssertNotNil(controller.networkButton.image)
        XCTAssertEqual(controller.networkButton.toolTip, identity)
        XCTAssertEqual(
            controller.networkButton.accessibilityValue() as? String,
            identity
        )
        XCTAssertTrue(
            controller.bottomButtonsStackView.arrangedSubviews.contains(
                controller.networkButton
            )
        )
        XCTAssertEqual(controller.networkButton.frame.width, 32)
        XCTAssertEqual(controller.accountsListBottomConstraint.constant, 62)
    }

    func testWalletListHidesApprovalControls() {
        let controller = instantiate(AccountsListViewController.self)
        controller.loadView()

        XCTAssertTrue(controller.bottomButtonsStackView.isHidden)
        XCTAssertTrue(controller.networkButton.isHidden)
        XCTAssertEqual(controller.accountsListBottomConstraint.constant, 0)
    }

    func testAccountSelectionSubmissionImmediatelyFencesControls() throws {
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: Networks.ethereum,
            resolve: { _, _ in fatalError() }
        )
        var completionCount = 0
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .selectAccount,
            completion: { _, _ in completionCount += 1 }
        )
        let controller = instantiate(AccountsListViewController.self)
        controller.accountSelection = session
        controller.loadView()

        controller.didClickSecondaryButton(controller.secondaryButton as Any)
        controller.didClickPrimaryButton(controller.primaryButton as Any)

        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(controller.addButton.isEnabled)
        XCTAssertFalse(controller.networkButton.isEnabled)
        XCTAssertFalse(controller.primaryButton.isEnabled)
        XCTAssertFalse(controller.secondaryButton.isEnabled)
        XCTAssertFalse(controller.tableView.isEnabled)
    }

    func testAccountSelectionTeardownCancelsMenusAndFencesNavigation() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = instantiate(AccountsListViewController.self)
        windowController.contentViewController = controller
        let addMenu = TrackingMenu()
        let tableMenu = TrackingMenu()
        controller.addButton.menu = addMenu
        controller.tableView.menu = tableMenu
        let originalContent = windowController.contentViewController

        controller.invalidateNativeApprovalReview()
        controller.invalidateNativeApprovalReview()
        _ = controller.perform(NSSelectorFromString("didClickImportAccount"))

        XCTAssertEqual(addMenu.cancellationCount, 1)
        XCTAssertEqual(tableMenu.cancellationCount, 1)
        XCTAssertTrue(windowController.contentViewController === originalContent)
    }

    func testAccountHeaderTeardownCancelsItsMenu() {
        let row = AccountsHeaderRowView()
        let button = NSButton()
        row.titleButton = button
        let menu = TrackingMenu()
        button.menu = menu

        row.cancelMenuTracking()

        XCTAssertEqual(menu.cancellationCount, 1)
    }

    func testBootstrapRetainsCoordinatorAcrossWalletAndReceiptFailures() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 1)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var current = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300)
        )
        var reloadResults = [false, true, true]
        var reloadCount = 0
        var materializationCount = 0
        var recordCount = 0
        var delays = [UInt64]()
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(current) }
        store.recordHandler = { _, _, _ in
            recordCount += 1
            current = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.now.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    runtimeInstanceIdentifier: runtime
                )
            )
            return .retryablePersistenceFailure
        }
        let environment = NativeApprovalCoordinator.Environment(
            now: { clock.now },
            wait: { delay in
                if delay < 1_000_000_000 {
                    delays.append(delay)
                } else {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            },
            prepareWithoutWallets: { _ in nil },
            reloadWallets: {
                reloadCount += 1
                return reloadResults.removeFirst()
            },
            prepare: { _ in
                materializationCount += 1
                return .approval(self.accountSelectionAction())
            }
        )
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: environment
        )

        let presentation = await coordinator.loadPresentation()

        guard case .approval = presentation else {
            return XCTFail("Expected approval")
        }
        XCTAssertEqual(reloadCount, 3)
        XCTAssertEqual(materializationCount, 2)
        XCTAssertEqual(recordCount, 1)
        XCTAssertEqual(delays, [250_000_000, 500_000_000])
        XCTAssertEqual(coordinator.state, .reviewing)
        XCTAssertEqual(
            current.nativeDeliveryReceipt?.runtimeInstanceIdentifier,
            runtime
        )
    }

    func testBootstrapUnavailableStopsAtTerminalDeadline() async {
        let clock = Clock()
        let handle = makeHandle(id: 10)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        var loadCount = 0
        var finishCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in
            loadCount += 1
            return .unavailable
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in
                    clock.now.addTimeInterval(ExtensionBridge.requestTTL)
                }
            )
        )
        coordinator.onFinished = { finishCount += 1 }

        let presentation = await coordinator.loadPresentation()

        guard case .finished = presentation else {
            return XCTFail("Expected finished presentation")
        }
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(finishCount, 1)
    }

    func testBootstrapRetryStopsAtRequestAdmissionDeadline() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 11)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(1)
        )
        var loadCount = 0
        var reloadCount = 0
        var receiptCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in
            loadCount += 1
            return .found(snapshot)
        }
        store.recordHandler = { _, _, _ in
            receiptCount += 1
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in clock.now.addTimeInterval(2) },
                prepareWithoutWallets: { _ in nil },
                reloadWallets: {
                    reloadCount += 1
                    return false
                }
            )
        )

        guard case .finished = await coordinator.loadPresentation() else {
            return XCTFail("Expected finished presentation")
        }
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(receiptCount, 0)
    }

    func testForeignReceiptSupersedesWithoutMaterialization() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 2)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var reloadCount = 0
        var recordCount = 0
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: UUID()
            )
        )
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.recordHandler = { _, _, _ in
            recordCount += 1
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { delay in
                    if delay >= 1_000_000_000 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                },
                prepareWithoutWallets: { _ in nil },
                reloadWallets: {
                    reloadCount += 1
                    return true
                },
                prepare: { _ in .approval(self.accountSelectionAction()) }
            )
        )

        let presentation = await coordinator.loadPresentation()

        guard case .superseded = presentation else {
            return XCTFail("Expected superseded delivery")
        }
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(reloadCount, 0)
        XCTAssertEqual(recordCount, 0)
    }

    func testReleasedForeignApprovalFinishesLocalWaitingCoordinatorOnce()
        async throws {
        let clock = Clock()
        let handle = makeHandle(id: 7)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let approving = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            phase: .approving
        )
        let queued = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: UUID()
            )
        )
        var loadCount = 0
        var finishCount = 0
        let finished = expectation(description: "local coordinator relinquished")
        let store = CoordinatorStore()
        store.loadHandler = { _ in
            loadCount += 1
            return .found(loadCount == 1 ? approving : queued)
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { _ in
                    XCTFail("A foreign approval must not be materialized")
                    return nil
                }
            )
        )
        coordinator.onFinished = {
            finishCount += 1
            finished.fulfill()
        }

        guard case .waiting = await coordinator.loadPresentation() else {
            return XCTFail("Expected waiting presentation")
        }
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()

        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(loadCount, 2)
    }

    func testWalletIndependentBootstrapSkipsReload() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 3)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300)
        )
        var reloadCount = 0
        var recordCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.recordHandler = { _, _, _ in
            recordCount += 1
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { delay in
                    if delay >= 1_000_000_000 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                },
                reloadWallets: {
                    reloadCount += 1
                    return true
                },
                prepare: { _ in fatalError("Wallet preparation is not expected") }
            )
        )

        let presentation = await coordinator.loadPresentation()

        guard case .approval = presentation else {
            return XCTFail("Expected approval")
        }
        XCTAssertEqual(reloadCount, 0)
        XCTAssertEqual(recordCount, 1)
    }

    func testBootstrapReusesEarlyReceiptWithoutRecordingAgain() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 15)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            )
        )
        var recordCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.recordHandler = { _, _, _ in
            recordCount += 1
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { delay in
                    if delay >= 1_000_000_000 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )

        guard case .approval = await coordinator.loadPresentation() else {
            return XCTFail("Expected approval")
        }
        XCTAssertEqual(recordCount, 0)
        XCTAssertEqual(coordinator.state, .reviewing)
    }

    func testBootstrapFailsClosedWhenRequiredEarlyReceiptIsLost() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 16)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300)
        )
        var recordCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.recordHandler = { _, _, _ in
            recordCount += 1
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in },
                prepareWithoutWallets: { _ in
                    XCTFail("A receipt-lost request must not be materialized")
                    return .approval(self.accountSelectionAction())
                }
            ),
            requiresExistingReceipt: true
        )

        guard case .superseded = await coordinator.loadPresentation() else {
            return XCTFail("Expected superseded presentation")
        }
        XCTAssertEqual(recordCount, 0)
        XCTAssertEqual(coordinator.state, .finished)
    }

    func testImmediateResponseRetriesWithoutPrematureFailure() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 12)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300)
        )
        let request = try XCTUnwrap(snapshot.request)
        let response = ResponseToExtension(
            for: request,
            payload: .error(.userRejected)
        )
        var completionCount = 0
        var failureCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.recordHandler = { _, _, _ in
            snapshot = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.now.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    runtimeInstanceIdentifier: runtime
                )
            )
            return .persisted
        }
        store.completeHandler = { _, _, _, _ in
            completionCount += 1
            return completionCount == 3
                ? .persisted
                : .retryablePersistenceFailure
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { _ in .response(response) }
            )
        )
        coordinator.onFailure = { failureCount += 1 }

        guard case .finished = await coordinator.loadPresentation() else {
            return XCTFail("Expected immediate completion")
        }
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(completionCount, 3)
        XCTAssertEqual(failureCount, 0)
    }

    func testStageOwnershipLossReconcilesStagedStoreState() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 13)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            )
        )
        let staged = expectation(description: "reconciled staged decision")
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.stageHandler = { _, _, _, _ in
            snapshot = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.now.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    runtimeInstanceIdentifier: runtime
                ),
                nativeDecisionStaged: true
            )
            return .ownershipLost
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        coordinator.onDecisionStaged = { staged.fulfill() }
        guard case .approval = await coordinator.loadPresentation() else {
            return XCTFail("Expected approval")
        }

        coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [staged], timeout: 1)

        XCTAssertEqual(coordinator.state, .staged)
    }

    func testStagedCoordinatorFinalizesThroughAmbientMonitor() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 140)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            ),
            nativeDecisionStaged: true
        )
        let finalized = expectation(description: "native decision finalized")
        let finished = expectation(description: "coordinator finished")
        var finalizationCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in await Task.yield() },
                finalizeNativeDecision: { requestedHandle in
                    XCTAssertEqual(requestedHandle, handle)
                    finalizationCount += 1
                    snapshot = try! self.approvalSnapshot(
                        handle: handle,
                        nonce: nonce,
                        deadline: clock.now.addingTimeInterval(300),
                        phase: .responded
                    )
                    finalized.fulfill()
                    return .responseReady
                }
            ),
            requiresExistingReceipt: true
        )
        coordinator.onFinished = { finished.fulfill() }

        guard case .waiting = await coordinator.loadPresentation() else {
            return XCTFail("Expected staged waiting presentation")
        }
        await fulfillment(of: [finalized, finished], timeout: 1)

        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(coordinator.state, .finished)
    }

    func testApprovalStagesWithExactReceiptOwner() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 4)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            )
        )
        let staged = expectation(description: "decision staged")
        var stagedNonce: ExtensionBridge.NativeDeliveryNonce?
        var stagedRuntime: UUID?
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.stageHandler = { _, value, owner, _ in
            stagedNonce = value
            stagedRuntime = owner
            staged.fulfill()
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { delay in
                    if delay >= 1_000_000_000 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        guard case .approval = await coordinator.loadPresentation() else {
            return XCTFail("Expected approval")
        }

        coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [staged], timeout: 1)

        XCTAssertEqual(stagedNonce, nonce)
        XCTAssertEqual(stagedRuntime, runtime)
        XCTAssertEqual(coordinator.state, .staged)
    }

    func testWindowCloseDuringStageDoesNotReviveFinishedState() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 5)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            )
        )
        let gate = StageGate()
        let stageStarted = expectation(description: "stage started")
        let rejectionFinished = expectation(description: "rejection finished")
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.stageHandler = { _, _, _, _ in
            stageStarted.fulfill()
            return await gate.run()
        }
        store.rejectHandler = { _, _, _ in
            rejectionFinished.fulfill()
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { delay in
                    if delay >= 1_000_000_000 {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        guard case .approval = await coordinator.loadPresentation() else {
            return XCTFail("Expected approval")
        }
        coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [stageStarted], timeout: 1)

        coordinator.reject()
        gate.resume(.retryablePersistenceFailure)
        await fulfillment(of: [rejectionFinished], timeout: 1)

        XCTAssertEqual(coordinator.state, .finished)
        gate.resume(.persisted)
        await Task.yield()
        XCTAssertEqual(coordinator.state, .finished)
    }

    func testRejectionUsesExactReceiptOwner() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 6)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            )
        )
        let rejected = expectation(description: "rejected")
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.rejectHandler = { _, value, owner in
            XCTAssertEqual(value, nonce)
            XCTAssertEqual(owner, runtime)
            rejected.fulfill()
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        guard case .approval = await coordinator.loadPresentation() else {
            return XCTFail("Expected approval")
        }

        coordinator.reject()
        await fulfillment(of: [rejected], timeout: 1)

        XCTAssertEqual(coordinator.state, .finished)
    }

    func testRejectionStopsAfterReceiptOwnershipChanges() async throws {
        let clock = Clock()
        let handle = makeHandle(id: 14)
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime
            )
        )
        var rejectionCount = 0
        let finished = expectation(description: "foreign receipt reconciled")
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.rejectHandler = { _, _, _ in
            rejectionCount += 1
            snapshot = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.now.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    runtimeInstanceIdentifier: UUID()
                )
            )
            return .ownershipLost
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: runtime,
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        coordinator.onFinished = { finished.fulfill() }
        guard case .approval = await coordinator.loadPresentation() else {
            return XCTFail("Expected approval")
        }

        coordinator.reject()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertEqual(coordinator.state, .finished)
    }

    private func titleTopSpacing(
        _ title: NSTextField,
        in view: NSView
    ) throws -> CGFloat {
        try XCTUnwrap(view.constraints.first {
            ($0.firstItem as? NSView) === title &&
                $0.firstAttribute == .top &&
                ($0.secondItem as? NSView) === view &&
                $0.secondAttribute == .top
        }).constant
    }

    private func approvalKey(
        id: Int,
        profileIdentifier: UUID? = nil
    ) -> ApprovalRouteKey {
        ApprovalRouteKey(
            handle: ExtensionBridge.Handle(
                id: id,
                token: .init(value: UUID()),
                profileIdentifier: profileIdentifier
            ),
            nativeDeliveryNonce: .init(value: UUID())
        )
    }

    private func approvalOrder(
        id: Int,
        sequence: Int = 0
    ) -> ApprovalInbox<String>.Order {
        ApprovalInbox<String>.Order(
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            sequence: sequence
        )
    }

    private func makeHandle(id: Int) -> ExtensionBridge.Handle {
        ExtensionBridge.Handle(
            id: id,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
    }

    private func accountSelectionAction() -> DappRequestAction {
        .selectAccount(.init(
            coinType: nil,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: Networks.ethereum,
            resolve: { _, _ in fatalError("Not exercised") }
        ))
    }

    private func approvalSnapshot(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        deadline: Date,
        receipt: ExtensionBridge.NativeDeliveryReceipt? = nil,
        phase: ExtensionBridge.Phase = .queued,
        nativeDecisionStaged: Bool = false
    ) throws -> ExtensionBridge.Snapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": handle.id,
            "name": "requestAccounts",
            "provider": InpageProvider.ethereum.rawValue,
            "host": "wallet.example",
            "configurationKey": "https://wallet.example",
            "enqueueAttempt": String(format: "%032x", handle.id),
            "admissionDeadline": Int(deadline.timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["address": ""],
        ])
        let request = try XCTUnwrap(SafariRequest(data: data))
        return ExtensionBridge.Snapshot(
            handle: handle,
            phase: phase,
            request: request,
            nativeDecisionStaged: nativeDecisionStaged,
            nativeDeliveryNonce: nonce,
            nativeDeliveryReceipt: receipt,
            host: request.host,
            configurationKey: request.configurationKey,
            revisions: ExtensionBridge.ProviderRevisions(rawValue: [
                "ethereum": 0,
                "solana": 0,
            ])!,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            enqueueAttempt: request.enqueueAttempt,
            sequence: 0
        )
    }

}

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

    @MainActor
    private final class AsyncGate<Value> {
        var continuation: CheckedContinuation<Value, Never>?
        var pendingResult: Value?

        func run() async -> Value {
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume(_ result: Value) {
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
        private var outstandingWrites = 0
        private(set) var maximumOutstandingWrites = 0
        var snapshot: ExtensionBridge.Snapshot?
        var loadHandler: ((ExtensionBridge.Handle) async ->
            ExtensionBridge.SnapshotResult)?
        var recordCount = 0
        var recordedOwner: ExtensionBridge.NativeDeliveryOwner?
        var recordHandler: ((
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryNonce,
            UUID,
            ExtensionBridge.NativeDeliveryOwner
        ) async -> ExtensionBridge.StoreMutationResult)?
        var unownedRejectHandler: (ExtensionBridge.Handle) async ->
            ExtensionBridge.StoreMutationResult = { _ in .persisted }
        var stageHandler: (
            ExtensionBridge.Handle,
            ExtensionBridge.NativeDeliveryNonce,
            UUID,
            DappApprovalDecision
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
            if let loadHandler { return await loadHandler(handle) }
            return snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }

        func recordNativeDeliveryReceipt(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID,
            owner: ExtensionBridge.NativeDeliveryOwner
        ) async -> ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            recordCount += 1
            recordedOwner = owner
            if let recordHandler {
                return await recordHandler(
                    handle, nativeDeliveryNonce, runtimeInstanceIdentifier, owner
                )
            }
            guard case .found(let current) = await load(handle: handle),
                  current.phase == .queued,
                  current.nativeDeliveryNonce == nativeDeliveryNonce else {
                return .ownershipLost
            }
            let receipt = ExtensionBridge.NativeDeliveryReceipt(
                nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier,
                owner: owner
            )
            if let existing = current.nativeDeliveryReceipt {
                return existing == receipt ? .persisted : .ownershipLost
            }
            guard loadHandler == nil else { return .ownershipLost }
            snapshot = ExtensionBridge.Snapshot(
                handle: current.handle,
                phase: current.phase,
                request: current.request,
                nativeDecisionStaged: current.nativeDecisionStaged,
                nativeDeliveryNonce: current.nativeDeliveryNonce,
                nativeDeliveryReceipt: receipt,
                host: current.host,
                configurationKey: current.configurationKey,
                revisions: current.revisions,
                createdAt: current.createdAt,
                enqueueAttempt: current.enqueueAttempt,
                sequence: current.sequence
            )
            return .persisted
        }

        func reject(handle: ExtensionBridge.Handle) async ->
            ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await unownedRejectHandler(handle)
        }

        func stageNativeDecision(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID,
            decision: DappApprovalDecision
        ) async -> ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await stageHandler(
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
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await completeHandler(
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
            beginWrite()
            defer { outstandingWrites -= 1 }
            return await rejectHandler(
                handle,
                nativeDeliveryNonce,
                runtimeInstanceIdentifier
            )
        }

        private func beginWrite() {
            outstandingWrites += 1
            maximumOutstandingWrites = max(maximumOutstandingWrites, outstandingWrites)
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

    func testRegistrationWaitsForRuntimeAndStartIsIdempotent() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.resumeAfterAuthentication()
        XCTAssertEqual(fixture.coordinator.state, .registered)
        XCTAssertEqual(fixture.store.recordCount, 0)
        start(fixture)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.store.recordedOwner, nativeOwner)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
    }

    func testInitialUnavailableValidationFinishesWithoutRetryOrUI() async throws {
        let fixture = try makeFixture()
        fixture.store.loadHandler = { _ in .unavailable }
        var inbox = ApprovalInbox<String>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        fixture.coordinator.onEvent = { event in
            if case .presentation(.finished) = event { inbox.remove(fixture.key) }
        }
        start(fixture)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(inbox.count, 0)
        XCTAssertNil(inbox.oldestActive(where: { _ in true }))
    }

    func testLateValidationCannotAcquireAfterCancellation() async throws {
        let fixture = try makeFixture()
        let gate = AsyncGate<ExtensionBridge.SnapshotResult>()
        let original = try XCTUnwrap(fixture.store.snapshot)
        let loadStarted = expectation(description: "validation load started")
        var loads = 0
        var rejections = 0
        fixture.store.loadHandler = { _ in
            loads += 1
            if loads == 1 {
                loadStarted.fulfill()
                return await gate.run()
            }
            return .found(original)
        }
        fixture.store.unownedRejectHandler = { _ in
            rejections += 1
            return .persisted
        }
        start(fixture)
        await fulfillment(of: [loadStarted], timeout: 1)
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .finished)
        gate.resume(.found(original))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testDelayedValidationStartsReceiptDeadlineAtAcquisition() async throws {
        let fixture = try makeFixture()
        let snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.now.addingTimeInterval(ExtensionBridge.requestTTL + 30)
        )
        fixture.store.snapshot = snapshot
        let gate = AsyncGate<ExtensionBridge.SnapshotResult>()
        let loadStarted = expectation(description: "validation suspended")
        fixture.store.loadHandler = { _ in
            loadStarted.fulfill()
            return await gate.run()
        }
        start(fixture)
        await fulfillment(of: [loadStarted], timeout: 1)
        fixture.clock.now.addTimeInterval(ExtensionBridge.requestTTL + 10)
        fixture.store.loadHandler = nil
        gate.resume(.found(snapshot))
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
    }

    func testForeignReceiptBeforeStartupNeverAuthenticatesOrPreparesWallets() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in XCTFail("Foreign ownership must not retry") },
            prepareWithoutWallets: { _ in
                XCTFail("Foreign ownership must not prepare a request")
                return nil
            },
            reloadWallets: {
                XCTFail("Foreign ownership must not reload wallets")
                return false
            }
        ))
        fixture.store.snapshot = try ownedSnapshot(fixture, runtime: UUID())
        start(fixture)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testLateBootstrapLoadCannotPresentAfterRejection() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let snapshot = try XCTUnwrap(fixture.store.snapshot)
        let gate = AsyncGate<ExtensionBridge.SnapshotResult>()
        let loadStarted = expectation(description: "bootstrap load started")
        let loadReturned = expectation(description: "canceled bootstrap load returned")
        fixture.store.loadHandler = { _ in
            loadStarted.fulfill()
            let result = await gate.run()
            loadReturned.fulfill()
            return result
        }
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [loadStarted], timeout: 1)
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        gate.resume(.found(snapshot))
        await fulfillment(of: [loadReturned], timeout: 1)
        XCTAssertEqual(fixture.coordinator.state, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        guard case .finished = fixture.events.presentations.first else {
            return XCTFail("A canceled bootstrap must only finish")
        }
    }

    func testCancellationWaitsForInFlightReceiptThenRejectsExactOwner() async throws {
        let fixture = try makeFixture()
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        fixture.store.recordHandler = { _, _, _, _ in await gate.run() }
        var rejections = 0
        fixture.store.rejectHandler = { handle, nonce, runtime in
            XCTAssertEqual(handle, fixture.key.handle)
            XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
            XCTAssertEqual(runtime, fixture.runtime)
            rejections += 1
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .acquiringReceipt(cancelRequested: false))
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        fixture.coordinator.cancelBeforeAuthentication()
        fixture.coordinator.cancelBeforeAuthentication()
        XCTAssertEqual(fixture.coordinator.state, .acquiringReceipt(cancelRequested: true))
        XCTAssertEqual(rejections, 0)
        fixture.store.snapshot = try ownedSnapshot(fixture)
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testStagedPreauthenticationCancellationWaitsSilentlyForExplicitRetry() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try ownedSnapshot(fixture, staged: true)
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A staged decision must not be rejected")
            return .ownershipLost
        }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .staged)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testPreauthenticationCancellationFinishesForForeignOrExecutingReceipt() async throws {
        for foreign in [false, true] {
            let fixture = try makeFixture()
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.store.snapshot = try ownedSnapshot(
                fixture,
                runtime: foreign ? UUID() : fixture.runtime,
                phase: foreign ? .queued : .approving,
                staged: true
            )
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Must not reject foreign or executing work")
                return .ownershipLost
            }
            fixture.coordinator.cancelBeforeAuthentication()
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(fixture.events.authenticationCount, 1)
        }
    }

    func testOwnedCancellationDeadlineAllowsLaterStorageRecovery() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { delay in
                if delay < 1_000_000_000 {
                    clock.now.addTimeInterval(ExtensionBridge.requestTTL)
                } else {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.loadHandler = { _ in .unavailable }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        fixture.store.loadHandler = nil
        fixture.store.snapshot = try ownedSnapshot(fixture)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        fixture.store.snapshot = nil
    }

    func testLostReceiptAfterAuthenticationCannotBeReacquired() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.now.addingTimeInterval(300)
        )
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 1)
        guard case .superseded = fixture.events.presentations.first else {
            return XCTFail("Expected lost ownership")
        }
    }

    func testReceiptAndWalletRetriesRemainOnTheirOwnSideOfAuthentication() async throws {
        let clock = Clock()
        var reloads = 0
        var preparations = 0
        var delays = [UInt64]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { delay in
                if delay < 1_000_000_000 { delays.append(delay) }
                else { try? await Task.sleep(nanoseconds: 60_000_000_000) }
            },
            prepareWithoutWallets: { _ in nil },
            reloadWallets: {
                reloads += 1
                return reloads > 1
            },
            prepare: { _ in
                preparations += 1
                return .approval(self.accountSelectionAction())
            }
        ))
        fixture.store.recordHandler = { _, _, _, _ in
            fixture.store.recordHandler = nil
            return .retryablePersistenceFailure
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(fixture.store.recordCount, 2)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(delays, [250_000_000, 250_000_000])
        fixture.store.snapshot = nil
    }

    func testPostauthenticationLoadingStopsAtAdmissionDeadline() async throws {
        let clock = Clock()
        var reloads = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in clock.now.addTimeInterval(301) },
            prepareWithoutWallets: { _ in nil },
            reloadWallets: {
                reloads += 1
                return false
            }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testPostauthenticationUnavailableLoadingStopsAtDeadline() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in clock.now.addTimeInterval(ExtensionBridge.requestTTL) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.loadHandler = { _ in .unavailable }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testApprovalInboxBoundsOnlyUnverifiedRoutesAndKeepsWalletIntentSeparate() async throws {
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 2)
        let first = try makeFixture()
        let second = try makeFixture()
        let third = try makeFixture()
        var intent = PendingWalletOpenIntent()
        intent.record()
        XCTAssertTrue(inbox.register(first.coordinator))
        XCTAssertTrue(inbox.register(second.coordinator))
        XCTAssertFalse(inbox.register(third.coordinator))
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        first.store.recordHandler = { _, _, _, _ in await gate.run() }
        start(first)
        await waitForState(first.coordinator, .acquiringReceipt(cancelRequested: false))
        XCTAssertFalse(inbox.register(third.coordinator))
        first.store.snapshot = try ownedSnapshot(first)
        gate.resume(.persisted)
        await waitForState(first.coordinator, .awaitingAuthentication)
        XCTAssertTrue(inbox.register(third.coordinator))
        XCTAssertTrue(inbox.activate("first", for: first.key))
        XCTAssertFalse(inbox.activate("again", for: first.key))
        XCTAssertFalse(inbox.register(first.coordinator))
        XCTAssertEqual(inbox.active(for: first.key), "first")
        XCTAssertTrue(intent.consume())
    }

    func testApprovalInboxDoesNotApplyProfileCapacityGlobally() async throws {
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 2)
        for id in 0..<24 {
            let fixture = try makeFixture(key: approvalKey(id: id, profileIdentifier: UUID()))
            XCTAssertTrue(inbox.register(fixture.coordinator))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            XCTAssertTrue(inbox.activate("active-\(id)", for: fixture.key))
        }
        XCTAssertEqual(inbox.count, 24)
    }

    func testApprovalInboxOrdersAuthenticationAndBreaksTiesDeterministically() async throws {
        var inbox = ApprovalInbox<String>()
        let newer = try makeFixture(createdAt: 200)
        let higherSequence = try makeFixture(createdAt: 100, sequence: 2)
        let firstTie = try makeFixture(createdAt: 100, sequence: 1)
        let secondTie = try makeFixture(createdAt: 100, sequence: 1)
        let unstarted = try makeFixture()
        let fixtures = [newer, higherSequence, firstTie, secondTie]
        for fixture in fixtures + [unstarted] {
            XCTAssertTrue(inbox.register(fixture.coordinator))
        }
        for fixture in fixtures.reversed() {
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
        }
        XCTAssertEqual(inbox.awaitingAuthenticationKeys, [firstTie.key, secondTie.key, higherSequence.key, newer.key])
        XCTAssertEqual(inbox.coordinators.map(\.handle), (fixtures + [unstarted]).map { $0.key.handle })
        for fixture in fixtures { XCTAssertTrue(inbox.activate("active", for: fixture.key)) }
        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, firstTie.key)
        inbox.remove(firstTie.key)
        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, secondTie.key)
    }

    func testSequentialCancellationsReleaseRegistrationsAndEmitOnce() async throws {
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 1)
        for _ in 0..<8 {
            let fixture = try makeFixture()
            XCTAssertTrue(inbox.register(fixture.coordinator))
            fixture.coordinator.cancelBeforeAuthentication()
            fixture.coordinator.cancelBeforeAuthentication()
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(fixture.events.presentations.count, 1)
            inbox.remove(fixture.key)
        }
        XCTAssertEqual(inbox.count, 0)
    }

    func testOldestApprovalWindowCanBeFrontmostWithoutClosingNewer() async throws {
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
            let fixture = try makeFixture(key: key, createdAt: TimeInterval(id))
            XCTAssertTrue(inbox.register(fixture.coordinator))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
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
        XCTAssertFalse(Agent.shouldReactivateApproval(in: .responding))
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
            network: nil
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
            network: Networks.ethereum
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
            network: network
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
            network: Networks.ethereum
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

    func testWalletIndependentBootstrapSkipsReloadAndDoesNotReacquireReceipt() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            reloadWallets: {
                XCTFail("Wallet-independent preparation must not reload wallets")
                return false
            },
            prepare: { _ in
                XCTFail("Wallet-independent preparation must not access wallets")
                return .approval(self.accountSelectionAction())
            }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        fixture.store.snapshot = nil
    }

    func testReleasedForeignApprovalFinishesLocalWaitingCoordinatorOnce() async throws {
        let clock = Clock()
        let gate = AsyncGate<Void>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in await gate.run() },
            prepareWithoutWallets: { _ in
                XCTFail("An executing approval must not be rematerialized")
                return nil
            }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .staged)
        fixture.store.snapshot = try ownedSnapshot(fixture, runtime: UUID())
        gate.resume(())
        await waitForState(fixture.coordinator, .finished)
        fixture.coordinator.reject()
        fixture.coordinator.cancelBeforeAuthentication()
        XCTAssertEqual(fixture.events.presentations.count, 2)
        guard case .waiting = fixture.events.presentations[0],
              case .finished = fixture.events.presentations[1] else {
            return XCTFail("Expected one waiting event followed by one finish")
        }
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
        store.recordHandler = { _, _, _, _ in
            snapshot = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.now.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    runtimeInstanceIdentifier: runtime,
                    owner: self.nativeOwner
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
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { _ in .response(response) }
            )
        )
        coordinator.onEvent = { if case .presentation(.rejecting) = $0 { failureCount += 1 } }

        guard case .finished = await loadPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected immediate completion")
        }
        XCTAssertEqual(coordinator.state, .finished)
        XCTAssertEqual(completionCount, 3)
        XCTAssertEqual(failureCount, 0)
    }

    func testEarlyResponseCancellationWaitsForTheInFlightWrite() async throws {
        for responseCommits in [false, true] {
            let clock = Clock()
            let writeStarted = expectation(description: "response write in flight")
            let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { request in
                    .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
                }
            ))
            fixture.store.completeHandler = { _, _, _, _ in
                writeStarted.fulfill()
                return await gate.run()
            }
            var rejections = 0
            fixture.store.rejectHandler = { _, _, _ in
                rejections += 1
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication()
            await fulfillment(of: [writeStarted], timeout: 1)

            fixture.coordinator.reject()
            fixture.coordinator.reject()
            XCTAssertEqual(fixture.coordinator.state, .responding)
            XCTAssertEqual(rejections, 0)
            gate.resume(responseCommits ? .persisted : .retryablePersistenceFailure)
            await waitForState(fixture.coordinator, .finished)

            XCTAssertEqual(rejections, responseCommits ? 0 : 1)
            XCTAssertEqual(fixture.events.presentations.count, 1)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }

    func testDelayedResponseKeepsItsIntentAndSerializesPersistence() async throws {
        let clock = Clock()
        let fourthWrite = expectation(description: "response retries after failure surface")
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { delay in
                clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                await Task.yield()
            },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var responses = [NSDictionary]()
        fixture.store.completeHandler = { _, _, _, response in
            responses.append(response.json as NSDictionary)
            if responses.count == 4 {
                fourthWrite.fulfill()
                return await gate.run()
            }
            return .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Persisting a response must not start a competing rejection")
            return .ownershipLost
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [fourthWrite], timeout: 1)

        XCTAssertEqual(fixture.coordinator.state, .responding)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        guard case .rejecting = fixture.events.presentations[0] else {
            return XCTFail("Expected one persistence failure surface")
        }
        fixture.coordinator.reject()
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(responses.count, 4)
        XCTAssertTrue(responses.allSatisfy { $0 == responses[0] })
        XCTAssertEqual(fixture.events.presentations.count, 2)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testEarlyResponseOwnershipLossPreparesCurrentRequestAgain() async throws {
        let clock = Clock()
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in await Task.yield() },
            prepareWithoutWallets: { request in
                preparations += 1
                return preparations == 1
                    ? .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
                    : .approval(self.accountSelectionAction())
            }
        ))
        var completionCount = 0
        fixture.store.completeHandler = { _, _, _, _ in
            completionCount += 1
            return .ownershipLost
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)

        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        guard case .approval = fixture.events.presentations[0] else {
            return XCTFail("Expected the newly prepared approval")
        }
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        fixture.store.snapshot = nil
    }

    func testSuccessfulInFlightStageWinsOverCancellation() async throws {
        let fixture = try makeFixture()
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        let stageStarted = expectation(description: "stage write in flight")
        fixture.store.stageHandler = { _, _, _, _ in
            stageStarted.fulfill()
            return await gate.run()
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A committed decision must not be rejected")
            return .ownershipLost
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [stageStarted], timeout: 1)

        fixture.coordinator.reject()
        fixture.store.snapshot = try ownedSnapshot(fixture, staged: true)
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .staged)

        XCTAssertEqual(fixture.events.presentations.count, 2)
        guard case .waiting = fixture.events.presentations[1] else {
            return XCTFail("Expected committed decision waiting state")
        }
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        fixture.store.snapshot = nil
    }

    func testThirdStageFailureStartsRejectionWithFreshBackoff() async throws {
        let clock = Clock()
        var delays = [UInt64]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { delay in
                if delay >= 1_000_000_000 {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                } else {
                    delays.append(delay)
                    await Task.yield()
                }
            },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) }
        ))
        var stages = 0
        var rejections = 0
        fixture.store.stageHandler = { _, _, _, _ in
            stages += 1
            return .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            rejections += 1
            return rejections == 1 ? .retryablePersistenceFailure : .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(stages, 3)
        XCTAssertEqual(rejections, 2)
        XCTAssertEqual(delays, [250_000_000, 500_000_000, 250_000_000])
        XCTAssertEqual(fixture.events.presentations.count, 3)
        guard case .rejecting = fixture.events.presentations[1],
              case .finished = fixture.events.presentations[2] else {
            return XCTFail("Expected one failure followed by completion")
        }
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testCancellationDuringThirdResponseWriteWaitsForItsResult() async throws {
        for responseCommits in [false, true] {
            let clock = Clock()
            let thirdWrite = expectation(description: "third response write")
            let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { request in
                    .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
                }
            ))
            var responses = 0
            var rejections = 0
            fixture.store.completeHandler = { _, _, _, _ in
                responses += 1
                if responses == 3 {
                    thirdWrite.fulfill()
                    return await gate.run()
                }
                return .retryablePersistenceFailure
            }
            fixture.store.rejectHandler = { _, _, _ in
                rejections += 1
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication()
            await fulfillment(of: [thirdWrite], timeout: 1)
            fixture.coordinator.reject()
            XCTAssertEqual(rejections, 0)
            gate.resume(responseCommits ? .persisted : .retryablePersistenceFailure)
            await waitForState(fixture.coordinator, .finished)

            XCTAssertEqual(responses, 3)
            XCTAssertEqual(rejections, responseCommits ? 0 : 1)
            XCTAssertEqual(fixture.events.presentations.count, 1)
            guard case .finished = fixture.events.presentations[0] else {
                return XCTFail("Cancellation must not introduce a failure surface")
            }
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }

    func testCancellationAfterThirdResponseFailurePreservesResponse() async throws {
        let clock = Clock()
        let retryWaiting = expectation(description: "waiting after third failure")
        let gate = AsyncGate<Void>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { delay in
                if delay == 1_000_000_000 {
                    retryWaiting.fulfill()
                    await gate.run()
                } else {
                    await Task.yield()
                }
            },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var responses = [NSDictionary]()
        fixture.store.completeHandler = { _, _, _, response in
            responses.append(response.json as NSDictionary)
            return responses.count == 4 ? .persisted : .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("The response intent must remain owned after three failures")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [retryWaiting], timeout: 1)
        fixture.coordinator.reject()
        gate.resume(())
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(responses.count, 4)
        XCTAssertTrue(responses.allSatisfy { $0 == responses[0] })
        XCTAssertEqual(fixture.events.presentations.count, 2)
        guard case .rejecting = fixture.events.presentations[0],
              case .finished = fixture.events.presentations[1] else {
            return XCTFail("Expected one failure followed by completion")
        }
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testFourthResponseFailureIsFirstToReconcileStorage() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in await Task.yield() },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        var loads = 0
        var loadsAtResponseAttempt = [Int]()
        let store = fixture.store
        store.loadHandler = { _ in
            loads += 1
            return store.snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }
        store.completeHandler = { _, _, _, _ in
            loadsAtResponseAttempt.append(loads)
            if loadsAtResponseAttempt.count == 4 { store.snapshot = nil }
            return .retryablePersistenceFailure
        }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(loadsAtResponseAttempt, [1, 1, 1, 1])
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        XCTAssertEqual(store.maximumOutstandingWrites, 1)
        store.loadHandler = nil
        store.completeHandler = { _, _, _, _ in .ownershipLost }
    }

    func testCancellationDuringThirdResponseRepreparationDelayRejects() async throws {
        let clock = Clock()
        let preparingAgain = expectation(description: "waiting to prepare again")
        let gate = AsyncGate<Void>()
        var waits = 0
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in
                waits += 1
                if waits == 3 {
                    preparingAgain.fulfill()
                    await gate.run()
                } else {
                    await Task.yield()
                }
            },
            prepareWithoutWallets: { request in
                preparations += 1
                return .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var responses = 0
        var rejections = 0
        fixture.store.completeHandler = { _, _, _, _ in
            responses += 1
            return responses == 3 ? .ownershipLost : .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            rejections += 1
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [preparingAgain], timeout: 1)
        fixture.coordinator.reject()
        gate.resume(())
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(responses, 3)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testResponseRepreparationRetainsPreparationBackoffAndResetsWriteBackoff() async throws {
        let clock = Clock()
        var reloads = 0
        var preparations = 0
        var delays = [UInt64]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { delay in
                delays.append(delay)
                await Task.yield()
            },
            prepareWithoutWallets: { _ in nil },
            reloadWallets: {
                reloads += 1
                return reloads > 1
            },
            prepare: { request in
                preparations += 1
                return .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var responses = 0
        fixture.store.completeHandler = { _, _, _, _ in
            responses += 1
            switch responses {
            case 2: return .ownershipLost
            case 4: return .persisted
            default: return .retryablePersistenceFailure
            }
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(reloads, 3)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(responses, 4)
        XCTAssertEqual(delays, [250_000_000, 250_000_000, 500_000_000, 250_000_000])
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testLifecycleMonitorSupersedesPendingStageWrite() async throws {
        let results: [ExtensionBridge.StoreMutationResult] = [
            .persisted, .ownershipLost, .retryablePersistenceFailure,
        ]
        for finalizationCompletes in [false, true] {
            for result in results {
                try await assertLifecycleMonitorSupersedesStage(
                    finalizationCompletes: finalizationCompletes,
                    stageResult: result,
                    suspendReconciliation: false
                )
            }
        }
    }

    func testLifecycleMonitorSupersedesPendingStageReconciliation() async throws {
        for finalizationCompletes in [false, true] {
            try await assertLifecycleMonitorSupersedesStage(
                finalizationCompletes: finalizationCompletes,
                stageResult: .ownershipLost,
                suspendReconciliation: true
            )
        }
    }

    private func assertLifecycleMonitorSupersedesStage(
        finalizationCompletes: Bool,
        stageResult: ExtensionBridge.StoreMutationResult,
        suspendReconciliation: Bool
    ) async throws {
        let clock = Clock()
        let monitorGate = AsyncGate<Void>()
        let stageGate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        let loadGate = AsyncGate<ExtensionBridge.SnapshotResult>()
        let operationStarted = expectation(description: "stage operation suspended")
        let operationResumed = expectation(description: "stale stage operation resumed")
        let unexpectedPresentation = expectation(description: "stale stage presentation")
        unexpectedPresentation.isInverted = true
        var finalizationCount = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            wait: { _ in await monitorGate.run() },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            finalizeNativeDecision: { _ in
                finalizationCount += 1
                return finalizationCompletes ? .responseReady : .pending
            }
        ))
        var stageCount = 0
        var rejectCount = 0
        var suspendNextLoad = false
        fixture.store.stageHandler = { _, _, _, _ in
            stageCount += 1
            if suspendReconciliation {
                suspendNextLoad = true
                return .ownershipLost
            }
            operationStarted.fulfill()
            let result = await stageGate.run()
            operationResumed.fulfill()
            return result
        }
        fixture.store.rejectHandler = { _, _, _ in
            rejectCount += 1
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let pendingSnapshot = try ownedSnapshot(fixture)
        let store = fixture.store
        var loadCount = 0
        store.loadHandler = { _ in
            loadCount += 1
            if suspendNextLoad {
                suspendNextLoad = false
                operationStarted.fulfill()
                let result = await loadGate.run()
                operationResumed.fulfill()
                return result
            }
            return store.snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [operationStarted], timeout: 1)

        store.snapshot = try ownedSnapshot(fixture, staged: true)
        monitorGate.resume(())
        let expectedState: NativeApprovalCoordinator.State = finalizationCompletes
            ? .finished : .staged
        await waitForState(fixture.coordinator, expectedState)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        let events = fixture.events
        fixture.coordinator.onEvent = { event in
            events.record(event)
            if case .presentation = event { unexpectedPresentation.fulfill() }
        }
        let loadsBeforeResuming = loadCount

        if suspendReconciliation {
            loadGate.resume(.found(pendingSnapshot))
        } else {
            stageGate.resume(stageResult)
        }
        await fulfillment(of: [operationResumed], timeout: 1)
        await fulfillment(of: [unexpectedPresentation], timeout: 0.05)

        XCTAssertEqual(fixture.coordinator.state, expectedState)
        XCTAssertEqual(stageCount, 1)
        XCTAssertEqual(rejectCount, 0)
        XCTAssertEqual(loadCount, loadsBeforeResuming)
        XCTAssertEqual(events.presentations.count, 2)
        XCTAssertEqual(store.maximumOutstandingWrites, 1)
        fixture.coordinator.onEvent = events.record
        store.loadHandler = nil
        store.snapshot = nil
        if !finalizationCompletes {
            monitorGate.resume(())
            await waitForState(fixture.coordinator, .finished)
        }
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
                runtimeInstanceIdentifier: runtime,
                owner: self.nativeOwner
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
                    runtimeInstanceIdentifier: runtime,
                    owner: self.nativeOwner
                ),
                nativeDecisionStaged: true
            )
            return .ownershipLost
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
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
        coordinator.onEvent = { if case .presentation(.waiting) = $0 { staged.fulfill() } }
        guard case .approval = await loadPresentation(coordinator, runtime: runtime) else {
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
                runtimeInstanceIdentifier: runtime,
                owner: self.nativeOwner
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
            )
        )
        let authentication = expectation(description: "receipt ready for authentication")
        let waiting = expectation(description: "staged waiting presentation")
        coordinator.onEvent = { event in
            switch event {
            case .authenticationRequired: authentication.fulfill()
            case .presentation(.waiting): waiting.fulfill()
            case .presentation(.finished): finished.fulfill()
            default: break
            }
        }
        coordinator.start(
            runtimeInstanceIdentifier: runtime,
            nativeDeliveryOwner: nativeOwner
        )
        await fulfillment(of: [authentication], timeout: 1)
        XCTAssertEqual(finalizationCount, 0)
        coordinator.resumeAfterAuthentication()
        await fulfillment(of: [waiting, finalized, finished], timeout: 1)

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
                runtimeInstanceIdentifier: runtime,
                owner: self.nativeOwner
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
        guard case .approval = await loadPresentation(coordinator, runtime: runtime) else {
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
                runtimeInstanceIdentifier: runtime,
                owner: self.nativeOwner
            )
        )
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
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
        guard case .approval = await loadPresentation(coordinator, runtime: runtime) else {
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
                runtimeInstanceIdentifier: runtime,
                owner: self.nativeOwner
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
            store: store,
            environment: .init(
                now: { clock.now },
                wait: { _ in },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        guard case .approval = await loadPresentation(coordinator, runtime: runtime) else {
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
                runtimeInstanceIdentifier: runtime,
                owner: self.nativeOwner
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
                    runtimeInstanceIdentifier: UUID(),
                    owner: self.nativeOwner
                )
            )
            return .ownershipLost
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
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
        coordinator.onEvent = { if case .presentation(.finished) = $0 { finished.fulfill() } }
        guard case .approval = await loadPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected approval")
        }

        coordinator.reject()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertEqual(coordinator.state, .finished)
    }

    private var nativeOwner: ExtensionBridge.NativeDeliveryOwner {
        .init(
            bundleURL: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
            marketingVersion: "1.0.99",
            buildVersion: "148"
        )!
    }

    private final class Events {
        var authenticationCount = 0
        var presentations = [NativeApprovalCoordinator.Presentation]()

        func record(_ event: NativeApprovalCoordinator.Event) {
            switch event {
            case .authenticationRequired: authenticationCount += 1
            case .presentation(let value): presentations.append(value)
            }
        }
    }

    private struct Fixture {
        let coordinator: NativeApprovalCoordinator
        let store: CoordinatorStore
        let runtime: UUID
        let key: ApprovalRouteKey
        let clock: Clock
        let events: Events
    }

    private func makeFixture(
        key: ApprovalRouteKey? = nil,
        createdAt: TimeInterval = 1_800_000_000,
        sequence: Int = 0,
        clock: Clock = Clock(),
        environment: NativeApprovalCoordinator.Environment? = nil
    ) throws -> Fixture {
        let key = key ?? approvalKey(id: 100)
        let store = CoordinatorStore()
        store.snapshot = try approvalSnapshot(
            handle: key.handle,
            nonce: key.nativeDeliveryNonce,
            deadline: clock.now.addingTimeInterval(300),
            createdAt: Date(timeIntervalSince1970: createdAt),
            sequence: sequence
        )
        let action = accountSelectionAction()
        let coordinator = NativeApprovalCoordinator(
            handle: key.handle,
            nativeDeliveryNonce: key.nativeDeliveryNonce,
            store: store,
            environment: environment ?? .init(
                now: { clock.now },
                wait: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) },
                prepareWithoutWallets: { _ in .approval(action) }
            )
        )
        let events = Events()
        coordinator.onEvent = events.record
        return Fixture(
            coordinator: coordinator,
            store: store,
            runtime: UUID(),
            key: key,
            clock: clock,
            events: events
        )
    }

    private func start(_ fixture: Fixture) {
        fixture.coordinator.start(
            runtimeInstanceIdentifier: fixture.runtime,
            nativeDeliveryOwner: nativeOwner
        )
    }

    private func ownedSnapshot(
        _ fixture: Fixture,
        runtime: UUID? = nil,
        phase: ExtensionBridge.Phase = .queued,
        staged: Bool = false
    ) throws -> ExtensionBridge.Snapshot {
        try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: fixture.key.nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtime ?? fixture.runtime,
                owner: nativeOwner
            ),
            phase: phase,
            nativeDecisionStaged: staged
        )
    }

    private func waitForState(
        _ coordinator: NativeApprovalCoordinator,
        _ expected: NativeApprovalCoordinator.State,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if coordinator.state == expected { return }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.state, expected, file: file, line: line)
    }

    private func loadPresentation(
        _ coordinator: NativeApprovalCoordinator,
        runtime: UUID
    ) async -> NativeApprovalCoordinator.Presentation {
        let ready = expectation(description: "first presentation")
        var presentation: NativeApprovalCoordinator.Presentation?
        let observer = coordinator.onEvent
        coordinator.onEvent = { [weak coordinator] event in
            observer?(event)
            switch event {
            case .authenticationRequired:
                coordinator?.resumeAfterAuthentication()
            case .presentation(let value):
                if presentation == nil {
                    presentation = value
                    ready.fulfill()
                }
            }
        }
        coordinator.start(
            runtimeInstanceIdentifier: runtime,
            nativeDeliveryOwner: nativeOwner
        )
        await fulfillment(of: [ready], timeout: 1)
        return presentation ?? .finished
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
            network: Networks.ethereum
        ))
    }

    private func approvalSnapshot(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        deadline: Date,
        receipt: ExtensionBridge.NativeDeliveryReceipt? = nil,
        phase: ExtensionBridge.Phase = .queued,
        nativeDecisionStaged: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        sequence: Int = 0
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
            createdAt: createdAt,
            enqueueAttempt: request.enqueueAttempt,
            sequence: sequence
        )
    }

}

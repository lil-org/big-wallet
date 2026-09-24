// ∅ 2026 lil org

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeApprovalCoordinatorTests: XCTestCase {

    func testSigningDecisionsCaptureTheAccountFromTheReviewedPresentation() async throws {
        let account = WalletAccount(
            address: "0x0000000000000000000000000000000000000001",
            coin: .ethereum,
            derivation: .custom,
            derivationPath: "m/44'/60'/0'/0/7",
            publicKey: "",
            extendedPublicKey: ""
        )
        let approvedAccount = WalletAccountDescriptor(walletID: "reviewed-wallet", account: account)
        let network = ResolvedEthereumNetwork(network: EthereumNetwork(
            chainId: 1, name: "Ethereum", symbol: "ETH",
            rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
            isTestnet: false, mightShowPrice: true, explorer: nil
        ), source: .custom)
        let transaction = Transaction(
            from: account.address, to: account.address, nonce: "0x1", gas: "0x5208",
            value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10)
        )
        let actions: [DappRequestAction] = [
            .approveMessage(SignMessageAction(
                subject: .signPersonalMessage, walletId: approvedAccount.walletID,
                account: account, meta: "reviewed", payload: .ethereumPersonalMessage(Data("reviewed".utf8))
            )),
            .approveTransaction(SendTransactionAction(
                transaction: transaction, resolvedNetwork: network,
                walletId: approvedAccount.walletID, account: account
            )),
        ]
        for action in actions {
            let clock = Clock()
            let waits = ScheduledWaits()
            var decisions = 0
            var capturedDecision: DappApprovalDecision?
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now }, uptime: { clock.uptime }, wait: waits.wait,
                prepareWithoutWallets: { _ in .approval(action) },
                attemptNativeDecision: { _, authorization in
                    decisions += 1
                    capturedDecision = authorization.decision
                    return .responseReady
                }
            ))
            defer { waits.resumeAll() }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication()
            await waitForState(fixture.coordinator, .reviewing)
            await waitForScheduledWait(waits, count: 1)
            switch action {
            case .approveMessage:
                fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network)
                XCTAssertEqual(fixture.coordinator.phase, .reviewing)
                fixture.coordinator.approveMessage(solanaCluster: nil)
            case .approveTransaction:
                fixture.coordinator.approveMessage(solanaCluster: nil)
                XCTAssertEqual(fixture.coordinator.phase, .reviewing)
                fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network)
            default:
                return XCTFail("Expected signing action")
            }
            await waitForState(fixture.coordinator, .finished)

            switch try XCTUnwrap(capturedDecision) {
            case .message(let decision):
                XCTAssertEqual(decision.approvedAccount, approvedAccount)
            case .transaction(let decision):
                XCTAssertEqual(decision.approvedAccount, approvedAccount)
            default:
                XCTFail("Expected an account-bound signing decision")
            }
            XCTAssertEqual(decisions, 1)
        }
    }

    func testReviewLifetimeInvalidatesBeforeCleanupAndDoesNotRetainParticipants() {
        let lifetime = NativeApprovalReviewLifetime()
        var cleanupCount = 0
        let participant = ReviewTeardownController()
        participant.onInvalidate = {
            XCTAssertFalse(lifetime.isActive)
            cleanupCount += 1
            lifetime.invalidate()
        }
        lifetime.register(participant)
        lifetime.register(participant)
        var discarded: ReviewTeardownController? = ReviewTeardownController()
        weak var weakDiscarded = discarded
        lifetime.register(discarded!)
        discarded = nil
        XCTAssertNil(weakDiscarded)

        lifetime.invalidate()
        lifetime.invalidate()
        XCTAssertEqual(cleanupCount, 1)

        let late = ReviewTeardownController()
        late.onInvalidate = { cleanupCount += 1; XCTAssertFalse(lifetime.isActive) }
        lifetime.register(late)
        XCTAssertEqual(cleanupCount, 2)
    }

    func testReviewLifetimeKeepsAllParticipantsAliveUntilCleanupFinishes() {
        let lifetime = NativeApprovalReviewLifetime()
        let first = ReviewTeardownController()
        var second: ReviewTeardownController? = ReviewTeardownController()
        weak var weakSecond = second
        var cleanedSecond = false
        first.onInvalidate = { second = nil }
        second?.onInvalidate = { cleanedSecond = true }
        lifetime.register(first)
        lifetime.register(second!)

        lifetime.invalidate()

        XCTAssertTrue(cleanedSecond)
        XCTAssertNil(weakSecond)
    }

    func testFreshReviewKeepsOldSelectionAndPasswordCallbacksInactive() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        let accounts = try XCTUnwrap(window.contentViewController as? AccountsListViewController)
        let selection = try XCTUnwrap(accounts.accountSelection)
        let oldReview = try XCTUnwrap(approval.currentReview)
        var passwordCompletions = 0
        let password = PasswordViewController.with(
            mode: .enter, reviewLifetime: oldReview,
            completion: { _ in passwordCompletions += 1 }
        )
        window.contentViewController = password
        _ = password.view

        let freshReview = try XCTUnwrap(approval.beginReview())
        XCTAssertFalse(oldReview.isActive)
        XCTAssertTrue(freshReview.isActive)
        selection.complete(accounts: [])
        password.cancelButtonTapped(password.cancelButton)
        _ = accounts.perform(NSSelectorFromString("didClickImportAccount"))

        XCTAssertTrue(window.contentViewController === password)
        XCTAssertEqual(passwordCompletions, 0)
        XCTAssertEqual(fixture.coordinator.phase, .reviewing)
        XCTAssertTrue(approval.currentReview === freshReview)
    }

    func testAccountNavigationSharesLifetimeAndCleansRetainedScreens() throws {
        let controller = accountSelectionController(
            manager: try accountSelectionWalletsManager(), mode: .selectAccount,
            selectedAccounts: []
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let lifetime = try XCTUnwrap(controller.accountSelection?.lifetime)
        let menu = TrackingMenu()
        controller.addButton.menu = menu
        _ = controller.perform(NSSelectorFromString("didClickImportAccount"))
        let imported = try XCTUnwrap(window.contentViewController as? ImportViewController)
        XCTAssertTrue(imported.accountSelection === controller.accountSelection)
        _ = imported.view

        lifetime.invalidate()
        lifetime.invalidate()
        imported.cancelButtonTapped(imported.cancelButton)
        _ = controller.perform(NSSelectorFromString("didClickImportAccount"))

        XCTAssertTrue(window.contentViewController === imported)
        XCTAssertEqual(menu.cancellationCount, 1)
    }

    func testOrdinaryWalletCloseStillFencesRetainedActions() throws {
        let controller = accountSelectionController(
            manager: try accountSelectionWalletsManager(), mode: nil,
            selectedAccounts: []
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let menu = TrackingMenu()
        controller.addButton.menu = menu
        let notification = Notification(name: NSWindow.willCloseNotification, object: window)

        controller.windowWillClose(notification)
        controller.windowWillClose(notification)
        _ = controller.perform(NSSelectorFromString("didClickImportAccount"))

        XCTAssertNil(controller.accountSelection)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertEqual(menu.cancellationCount, 1)
    }

    func testSelectionSubmissionKeepsReviewAliveAndFencesReentrantSubmission() {
        let lifetime = NativeApprovalReviewLifetime()
        var completions = 0
        let session = NativeAccountSelectionSession(
            action: .init(coinType: nil, selectedAccounts: [],
                          initiallyConnectedProviders: [], network: nil),
            mode: .selectAccount, lifetime: lifetime
        ) { _, _ in completions += 1 }

        session.complete(accounts: []) {
            XCTAssertTrue(session.hasCompleted)
            XCTAssertTrue(lifetime.isActive)
            session.complete(accounts: nil)
        }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(lifetime.isActive)
        lifetime.invalidate()
        session.complete(accounts: nil)
        XCTAssertEqual(completions, 1)
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000) {
            didSet { uptime += max(0, now.timeIntervalSince(oldValue)) }
        }
        private(set) var uptime: TimeInterval = 0
        func advanceUptime(_ interval: TimeInterval) { uptime += interval }
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

    @MainActor
    private final class ScheduledWaits {
        private(set) var delays = [UInt64]()
        private var continuations = [Int: CheckedContinuation<Void, Never>]()

        func wait(_ delay: UInt64) async {
            let index = delays.count
            delays.append(delay)
            await withCheckedContinuation { continuations[index] = $0 }
        }

        func resume(_ index: Int) {
            continuations.removeValue(forKey: index)?.resume()
        }

        func isPending(_ index: Int) -> Bool {
            continuations[index] != nil
        }

        func resumeAll() {
            let pending = continuations.values
            continuations.removeAll()
            for continuation in pending { continuation.resume() }
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
            ExtensionBridge.NativeDeliveryOwner
        ) async -> ExtensionBridge.StoreMutationResult)?
        var unownedRejectHandler: (ExtensionBridge.Handle) async ->
            ExtensionBridge.StoreMutationResult = { _ in .persisted }
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
            owner: ExtensionBridge.NativeDeliveryOwner
        ) async -> ExtensionBridge.StoreMutationResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            recordCount += 1
            recordedOwner = owner
            if let recordHandler {
                return await recordHandler(
                    handle, nativeDeliveryNonce, owner
                )
            }
            guard case .found(let current) = await load(handle: handle),
                  case .queued(let request, _) = current.state,
                  current.nativeDeliveryNonce == nativeDeliveryNonce else {
                return .ownershipLost
            }
            let receipt = ExtensionBridge.NativeDeliveryReceipt(
                nativeDeliveryNonce: nativeDeliveryNonce,
                owner: owner
            )
            if let existing = current.nativeDeliveryReceipt {
                return existing == receipt ? .persisted : .ownershipLost
            }
            guard loadHandler == nil else { return .ownershipLost }
            snapshot = ExtensionBridge.Snapshot(
                handle: current.handle,
                state: .queued(request: request, approval: .delivered(receipt)),
                nativeDeliveryNonce: current.nativeDeliveryNonce,
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

        private(set) var interruptionCount = 0
        var interruptionHandler: (() async -> ExtensionBridge.NativeInterruptionResult)?

        func interruptNativeApproval(
            handle: ExtensionBridge.Handle,
            nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) async -> ExtensionBridge.NativeInterruptionResult {
            beginWrite()
            defer { outstandingWrites -= 1 }
            interruptionCount += 1
            if let interruptionHandler { return await interruptionHandler() }
            return .interrupted
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

    private final class PopupRecordingMenu: NSMenu {
        var onPopup: (() -> Void)?

        override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
            onPopup?()
            MainActor.assumeIsolated {
                delegate?.menuDidClose?(self)
            }
            return false
        }
    }

    private final class ReviewTeardownController: NSViewController, NativeApprovalReviewTeardown {
        var onInvalidate: (() -> Void)?

        func invalidateNativeApprovalReview() {
            onInvalidate?()
        }
    }

    private final class TrackingWindow: NSWindow {
        private(set) var activationCount = 0
        private(set) var deminiaturizationCount = 0

        override func deminiaturize(_ sender: Any?) {
            deminiaturizationCount += 1
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
        XCTAssertEqual(fixture.coordinator.phase, .registered)
        XCTAssertEqual(fixture.store.recordCount, 0)
        start(fixture)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.store.recordedOwner, nativeOwner(runtime: fixture.runtime))
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
    }

    func testUnavailableValidationBecomesDormantAndExplicitlyRecovers() async throws {
        let clock = Clock()
        var reads = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                await Task.yield()
            }
        ))
        fixture.store.loadHandler = { _ in reads += 1; return .unavailable }
        start(fixture)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertTrue(fixture.coordinator.isDormant)
        XCTAssertTrue(fixture.coordinator.countsTowardUnverifiedLimit)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        let pausedReads = reads
        start(fixture)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, pausedReads)
        fixture.store.loadHandler = nil
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
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

    func testDelayedValidationCannotExtendRegistrationLifetime() async throws {
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
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testForeignReceiptBeforeStartupNeverAuthenticatesOrPreparesWallets() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
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
        XCTAssertEqual(fixture.store.recordCount, 0)
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
        var didSuspend = false
        fixture.store.loadHandler = { _ in
            if didSuspend { return .found(snapshot) }
            didSuspend = true
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
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        guard case .waiting = fixture.events.presentations.first,
              case .finished = fixture.events.presentations.last else {
            return XCTFail("A canceled bootstrap must wait for rejection and finish without a review")
        }
    }

    func testCancellationWaitsForInFlightReceiptThenRejectsExactOwner() async throws {
        let fixture = try makeFixture()
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        fixture.store.recordHandler = { _, _, _ in await gate.run() }
        var rejections = 0
        fixture.store.rejectHandler = { handle, nonce, runtime in
            XCTAssertEqual(handle, fixture.key.handle)
            XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
            XCTAssertEqual(runtime, fixture.runtime)
            rejections += 1
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .acquiringReceipt)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        fixture.coordinator.cancelBeforeAuthentication()
        fixture.coordinator.cancelBeforeAuthentication()
        XCTAssertEqual(fixture.coordinator.phase, .acquiringReceipt)
        XCTAssertEqual(rejections, 0)
        fixture.store.snapshot = try ownedSnapshot(fixture)
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testRecreatedCoordinatorRequiresFreshReviewBeforeClaiming() async throws {
        let fixture = try makeFixture()
        fixture.store.snapshot = try ownedSnapshot(fixture)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }

    func testPreauthenticationCancellationFinishesForForeignOrExecutingReceipt() async throws {
        for foreign in [false, true] {
            let fixture = try makeFixture()
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.store.snapshot = try ownedSnapshot(
                fixture,
                runtime: foreign ? UUID() : fixture.runtime,
                phase: foreign ? .queued : .approving
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

    func testAuthenticationWaitingExpiresAndLeavesInbox() async throws {
        let fixture = try makeFixture()
        let deadline = fixture.clock.now.addingTimeInterval(0.02)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: deadline
        )
        let finished = expectation(description: "unauthenticated approval expired")
        var inbox = ApprovalInbox<String>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        let events = fixture.events
        let key = fixture.key
        fixture.coordinator.onEvent = { event in
            events.record(event, coordinator: fixture.coordinator)
            if case .presentationChanged = event,
               case .finished? = fixture.coordinator.currentPresentation?.presentation {
                inbox.remove(key)
                finished.fulfill()
            }
        }
        defer { fixture.coordinator.onEvent = nil }

        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.clock.now = deadline
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(inbox.count, 0)
        XCTAssertEqual(events.authenticationCount, 1)
        XCTAssertEqual(events.presentations.count, 1)
        fixture.coordinator.resumeAfterAuthentication()
        fixture.coordinator.cancelBeforeAuthentication()
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(events.presentations.count, 1)
    }

    func testAuthenticationWaitingDoesNotExpireBeforeRecordedDeadline() async throws {
        let fixture = try makeFixture()
        let deadline = fixture.clock.now.addingTimeInterval(0.02)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: deadline
        )
        let prematureFinish = expectation(description: "deadline has not elapsed")
        prematureFinish.isInverted = true
        fixture.coordinator.onEvent = { event in
            if case .presentationChanged = event,
               case .finished? = fixture.coordinator.currentPresentation?.presentation { prematureFinish.fulfill() }
        }
        start(fixture)
        await fulfillment(of: [prematureFinish], timeout: 0.1)
        XCTAssertEqual(fixture.coordinator.phase, .awaitingAuthentication)

        let finished = expectation(description: "recorded deadline elapsed")
        fixture.coordinator.onEvent = { event in
            if case .presentationChanged = event,
               case .finished? = fixture.coordinator.currentPresentation?.presentation { finished.fulfill() }
        }
        fixture.clock.now = deadline
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixture.coordinator.phase, .finished)
    }

    func testAuthenticationExpiryDoesNotInterruptCancellationPersistence() async throws {
        let fixture = try makeFixture()
        let deadline = fixture.clock.now.addingTimeInterval(0.02)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: deadline
        )
        let writeStarted = expectation(description: "rejection write started")
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        fixture.store.rejectHandler = { _, _, _ in
            writeStarted.fulfill()
            return await gate.run()
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.cancelBeforeAuthentication()
        await fulfillment(of: [writeStarted], timeout: 1)

        fixture.clock.now = deadline
        let prematureFinish = expectation(description: "rejection write still pending")
        prematureFinish.isInverted = true
        fixture.coordinator.onEvent = { event in
            if case .presentationChanged = event,
               case .finished? = fixture.coordinator.currentPresentation?.presentation { prematureFinish.fulfill() }
        }
        await fulfillment(of: [prematureFinish], timeout: 0.1)
        XCTAssertEqual(
            fixture.coordinator.phase,
            .rejecting
        )

        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator, events = fixture.events] in
            events.record($0, coordinator: coordinator)
        }
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testOwnedCancellationDeadlineExpiresAuthenticationWaiting() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
            wait: { delay in
                if delay <= 1_000_000_000 {
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
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        fixture.store.loadHandler = nil
        fixture.store.snapshot = try ownedSnapshot(fixture)
        fixture.coordinator.resumeAfterAuthentication()
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }

    func testPreauthenticationCancellationCannotRejectAfterOwnedReceiptDisappears() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle, nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.now.addingTimeInterval(300)
        )
        fixture.store.unownedRejectHandler = { _ in
            XCTFail("Previously owned cancellation must never fall back to unowned rejection")
            return .persisted
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("The receipt is no longer owned")
            return .persisted
        }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
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
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
            wait: { delay in
                if reloads < 2 { await Task.yield() }
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
        fixture.store.recordHandler = { _, _, _ in
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
        fixture.store.snapshot = nil
    }

    func testPostauthenticationLoadingStopsAtAdmissionDeadline() async throws {
        let clock = Clock()
        var reloads = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
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
            uptime: { clock.uptime },
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
        first.store.recordHandler = { _, _, _ in await gate.run() }
        start(first)
        await waitForState(first.coordinator, .acquiringReceipt)
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
        XCTAssertEqual(Agent.ActiveApproval.finishedApprovalWindowAction(
            windowNumber: nil,
            isVisible: true,
            isMiniaturized: false
        ), .none)
        XCTAssertEqual(Agent.ActiveApproval.finishedApprovalWindowAction(
            windowNumber: 42,
            isVisible: false,
            isMiniaturized: false
        ), .close)
        XCTAssertEqual(Agent.ActiveApproval.finishedApprovalWindowAction(
            windowNumber: 42,
            isVisible: true,
            isMiniaturized: false
        ), .closeAndActivate)
        XCTAssertEqual(Agent.ActiveApproval.finishedApprovalWindowAction(
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

    func testReactivationCapabilitiesFollowApprovalLifecycle() async throws {
        let fixture = try makeFixture()
        XCTAssertFalse(fixture.coordinator.canReactivate)
        XCTAssertFalse(fixture.coordinator.hasAuthenticated)
        XCTAssertTrue(fixture.coordinator.countsTowardUnverifiedLimit)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertTrue(fixture.coordinator.isAwaitingAuthentication)
        XCTAssertFalse(fixture.coordinator.canReactivate)
        XCTAssertFalse(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertTrue(fixture.coordinator.canReactivate)
        XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertFalse(fixture.coordinator.canReactivate)
        XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
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
            reviewLifetime: NativeApprovalReviewLifetime(),
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
            lifetime: NativeApprovalReviewLifetime(),
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
            lifetime: NativeApprovalReviewLifetime(),
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
            lifetime: NativeApprovalReviewLifetime(),
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
            lifetime: NativeApprovalReviewLifetime(),
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

    func testAccountSelectionQueriesDoNotChangeSelectedAccounts() throws {
        let manager = try accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let original = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])

        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = accountSelectionController(
                manager: manager,
                mode: mode,
                selectedAccounts: [original]
            )

            for _ in 0..<3 {
                XCTAssertFalse(controller.tableView(controller.tableView, shouldSelectRow: 2))
                XCTAssertEqual(controller.accountSelection?.selectedAccounts, [original])
            }
        }
    }

    func testWalletListKeyboardSelectionOpensMenuAndAllowsNextClick() async throws {
        let controller = instantiate(AccountsListViewController.self)
        controller.walletsManager = try accountSelectionWalletsManager()
        controller.loadView()
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))
        let menu = PopupRecordingMenu()
        menu.delegate = controller
        table.menu = menu
        let opened = [
            expectation(description: "initial click menu"),
            expectation(description: "keyboard menu"),
            expectation(description: "subsequent click menu")
        ]
        var rows = [Int]()
        menu.onPopup = { [weak table] in
            rows.append(table?.selectedRow ?? -1)
            if rows.count <= opened.count {
                opened[rows.count - 1].fulfill()
            }
        }

        try clickAccountRow(2, in: controller, window: window)
        await fulfillment(of: [opened[0]], timeout: 1)
        try pressDownArrow(in: table, window: window)
        await fulfillment(of: [opened[1]], timeout: 1)
        XCTAssertEqual(table.selectedRow, -1)

        try clickAccountRow(3, in: controller, window: window)
        await fulfillment(of: [opened[2]], timeout: 1)
        XCTAssertEqual(rows, [2, 1, 3])
        XCTAssertEqual(table.selectedRow, -1)
    }

    func testWalletListPendingMenuDoesNotOpenAfterSelectionClears() async throws {
        let controller = instantiate(AccountsListViewController.self)
        controller.walletsManager = try accountSelectionWalletsManager()
        controller.loadView()
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))
        let menu = PopupRecordingMenu()
        menu.delegate = controller
        table.menu = menu
        let opened = expectation(description: "cancelled menu stays closed")
        opened.isInverted = true
        menu.onPopup = { opened.fulfill() }

        try pressDownArrow(in: table, window: window)
        XCTAssertEqual(table.selectedRow, 1)
        table.deselectAll(nil)

        await fulfillment(of: [opened], timeout: 0.1)
        XCTAssertEqual(table.selectedRow, -1)
    }

    func testAccountSelectionClickSwitchesAndDeselectsOncePreservingOtherCoin() throws {
        let manager = try accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let accounts = wallet.accounts.map {
            SpecificWalletAccount(walletId: wallet.id, account: $0)
        }

        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = accountSelectionController(
                manager: manager,
                mode: mode,
                selectedAccounts: [accounts[0], accounts[2]]
            )
            let window = accountSelectionWindow(controller: controller)
            defer { window.close() }

            try clickAccountRow(2, in: controller, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[1], accounts[2]])

            try clickAccountRow(2, in: controller, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[2]])

            try clickAccountRow(1, in: controller, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[0], accounts[2]])
            XCTAssertTrue(controller.primaryButton.isEnabled)
        }
    }

    func testAccountPickerKeyboardNavigatesAndActivatesWithoutSubmitting() throws {
        let manager = try accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let accounts = wallet.accounts.map {
            SpecificWalletAccount(walletId: wallet.id, account: $0)
        }
        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = accountSelectionController(manager: manager, mode: mode, selectedAccounts: [])
            let window = accountSelectionWindow(controller: controller)
            defer { window.close() }
            let table = try XCTUnwrap(controller.tableView)
            XCTAssertTrue(window.makeFirstResponder(table))
            XCTAssertFalse(controller.primaryButton.isEnabled)

            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 1)
            let focusedRow = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true))
            XCTAssertEqual(focusedRow.interiorBackgroundStyle, .normal)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [])
            try pressKey(" ", keyCode: 49, in: table, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[0]])
            XCTAssertTrue(controller.primaryButton.isEnabled)

            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 2)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[0]])
            try pressKey("\r", keyCode: 36, in: table, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[1]])
            XCTAssertTrue(table.isEnabled)

            try pressDownArrow(in: table, window: window)
            try pressKey(" ", keyCode: 49, in: table, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[1], accounts[2]])
            try pressKey(" ", keyCode: 49, in: table, window: window, isRepeat: true)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[1], accounts[2]])
            try pressKey(" ", keyCode: 49, in: table, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [accounts[1]])

            try pressKey("\u{f700}", keyCode: 126, in: table, window: window)
            XCTAssertEqual(table.selectedRow, 2)
            try pressKey("\u{3}", keyCode: 76, in: table, window: window)
            XCTAssertEqual(controller.accountSelection?.selectedAccounts, [])
            XCTAssertFalse(controller.primaryButton.isEnabled)
        }
    }

    func testAccountPickerKeyboardSkipsDisabledCoinsAndFollowsMouseFocus() throws {
        let manager = try accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let account = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])
        let controller = accountSelectionController(
            manager: manager,
            mode: .selectAccount,
            selectedAccounts: [account],
            coinType: .ethereum
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertEqual(table.selectedRow, 1)

        try pressDownArrow(in: table, window: window)
        try pressDownArrow(in: table, window: window)
        XCTAssertEqual(table.selectedRow, 2)
        try pressKey(" ", keyCode: 49, in: table, window: window)
        try clickAccountRow(1, in: controller, window: window)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(controller.accountSelection?.selectedAccounts, [account])
        try pressKey(" ", keyCode: 49, in: table, window: window)
        XCTAssertEqual(controller.accountSelection?.selectedAccounts, [])
        XCTAssertFalse(controller.primaryButton.isEnabled)

        controller.accountSelection?.lifetime.invalidate()
        try pressKey(" ", keyCode: 49, in: table, window: window)
        XCTAssertEqual(controller.accountSelection?.selectedAccounts, [])
    }

    func testEmptyWalletOptionsSupportKeyboardAndMouseImport() throws {
        let reader = KeychainCopyMatchingStub()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        XCTAssertTrue(manager.reloadFromStore())
        let cases: [(NativeAccountSelectionMode?, Bool)] = [(nil, true), (.switchAccount, true), (nil, false)]
        for (mode, useKeyboard) in cases {
            let controller = accountSelectionController(manager: manager, mode: mode, selectedAccounts: [])
            let window = accountSelectionWindow(controller: controller)
            defer { window.close() }
            let table = try XCTUnwrap(controller.tableView)
            XCTAssertTrue(window.makeFirstResponder(table))

            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 0)
            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 1)
            try pressKey("\u{f700}", keyCode: 126, in: table, window: window)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertTrue(window.contentViewController === controller)
            XCTAssertNil(window.attachedSheet)

            if useKeyboard {
                try pressDownArrow(in: table, window: window)
                try pressKey(" ", keyCode: 49, in: table, window: window)
            } else {
                try clickAccountRow(1, in: controller, window: window)
            }
            XCTAssertTrue(window.contentViewController is ImportViewController)
            XCTAssertTrue(manager.wallets.isEmpty)
        }
    }

    func testEmptyWalletCreateCanBeActivatedWithReturn() throws {
        let reader = KeychainCopyMatchingStub()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        XCTAssertTrue(manager.reloadFromStore())
        let controller = accountSelectionController(manager: manager, mode: nil, selectedAccounts: [])
        let window = accountSelectionWindow(controller: controller)
        let windowController = WalletWindowController(window: window)
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        defer { windowController.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))

        try pressDownArrow(in: table, window: window)
        try pressKey("\r", keyCode: 36, in: table, window: window)
        XCTAssertEqual(table.selectedRow, -1)
        let confirmation = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(manager.wallets.isEmpty)
        window.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
        confirmation.orderOut(nil)
    }

    func testWalletListCancelledDragClearsSelectionAndAllowsNextClick() async throws {
        let controller = instantiate(AccountsListViewController.self)
        controller.walletsManager = try accountSelectionWalletsManager()
        controller.loadView()
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        let menu = PopupRecordingMenu()
        menu.delegate = controller
        table.menu = menu

        for (destination, nextRow) in [(2, 3), (0, 2)] {
            let opened = expectation(description: "menu after cancelled drag to row \(destination)")
            var rows = [Int]()
            menu.onPopup = { [weak table] in
                rows.append(table?.selectedRow ?? -1)
                opened.fulfill()
            }

            try clickAccountRow(1, endingAt: destination, in: controller, window: window)
            XCTAssertEqual(table.selectedRow, -1)
            XCTAssertTrue(rows.isEmpty)

            try clickAccountRow(nextRow, in: controller, window: window)
            await fulfillment(of: [opened], timeout: 1)
            XCTAssertEqual(rows, [nextRow])
            XCTAssertEqual(table.selectedRow, -1)
        }
    }

    func testAccountSelectionClickIgnoresOtherCoinAndCanClearSelection() throws {
        let manager = try accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let original = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])
        let replacement = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[1])
        let controller = accountSelectionController(
            manager: manager,
            mode: .selectAccount,
            selectedAccounts: [original],
            coinType: .ethereum
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }

        try clickAccountRow(3, in: controller, window: window)
        XCTAssertEqual(controller.accountSelection?.selectedAccounts, [original])

        try clickAccountRow(2, in: controller, window: window)
        XCTAssertEqual(controller.accountSelection?.selectedAccounts, [replacement])
        XCTAssertTrue(controller.primaryButton.isEnabled)

        try clickAccountRow(2, in: controller, window: window)
        XCTAssertEqual(controller.accountSelection?.selectedAccounts, [])
        XCTAssertFalse(controller.primaryButton.isEnabled)
    }

    func testAccountSelectionTeardownCancelsMenusAndFencesNavigation() throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = instantiate(AccountsListViewController.self)
        let lifetime = NativeApprovalReviewLifetime()
        controller.accountSelection = NativeAccountSelectionSession(
            action: SelectAccountAction(coinType: nil, selectedAccounts: [],
                                        initiallyConnectedProviders: [], network: nil),
            mode: .selectAccount, lifetime: lifetime, completion: { _, _ in }
        )
        windowController.contentViewController = controller
        let addMenu = TrackingMenu()
        let tableMenu = TrackingMenu()
        controller.addButton.menu = addMenu
        controller.tableView.menu = tableMenu
        let originalContent = windowController.contentViewController

        lifetime.invalidate()
        lifetime.invalidate()
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
            uptime: { clock.uptime },
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

    func testCoordinatorWithoutLocalAuthorizationInterruptsOwnedExecution() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.interruptionCount, 1)
        guard case .interrupted? = fixture.events.presentations.last else {
            return XCTFail("Lost authorization must not wait for execution")
        }
        fixture.coordinator.retryRecovery()
        XCTAssertEqual(fixture.store.interruptionCount, 1)
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
                    owner: self.nativeOwner(runtime: runtime)
                )
            )
            return .persisted
        }
        store.completeHandler = { _, _, _, _ in
            completionCount += 1
            return completionCount == 7
                ? .persisted
                : .retryablePersistenceFailure
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            store: store,
            environment: .init(
                now: { clock.now },
                uptime: { clock.uptime },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { _ in .response(response) }
            )
        )
        coordinator.onEvent = { [weak coordinator] event in
            if case .presentationChanged = event,
               case .rejecting? = coordinator?.currentPresentation?.presentation { failureCount += 1 }
        }

        guard case .finished = await loadPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected immediate completion")
        }
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertGreaterThan(completionCount, 3)
        XCTAssertEqual(failureCount, 0)
    }

    func testLateResponseSettlesBeforeRecoveryCanRetry() async throws {
        for commits in [false, true] {
            let clock = Clock()
            let started = expectation(description: "response in flight")
            let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now }, uptime: { clock.uptime },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { request in
                    .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
                }
            ))
            var writes = 0
            fixture.store.completeHandler = { _, _, _, _ in
                writes += 1
                started.fulfill()
                return await gate.run()
            }
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Closing cannot replace an accepted response")
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication()
            await fulfillment(of: [started], timeout: 1)
            clock.now.addTimeInterval(11)
            fixture.coordinator.reject()
            fixture.coordinator.retryRecovery()
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(fixture.coordinator.phase, .responding)
            gate.resume(commits ? .persisted : .retryablePersistenceFailure)
            await waitForState(fixture.coordinator, commits ? .finished : .paused)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }

    func testDelayedResponseKeepsItsIntentAndSerializesPersistence() async throws {
        let clock = Clock()
        let retryWrite = expectation(description: "response retries through a storage outage")
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
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
            if responses.count == 7 {
                retryWrite.fulfill()
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
        await fulfillment(of: [retryWrite], timeout: 1)

        XCTAssertEqual(fixture.coordinator.phase, .responding)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
        fixture.coordinator.reject()
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .finished)

        XCTAssertGreaterThan(responses.count, 3)
        XCTAssertTrue(responses.allSatisfy { $0 == responses[0] })
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testResponseOwnershipLossRepeatedlyPausesWithoutRepreparing() async throws {
        let clock = Clock()
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { _ in XCTFail("Semantic failure must pause") },
            prepareWithoutWallets: { request in
                preparations += 1
                return .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var responses = [NSDictionary]()
        fixture.store.completeHandler = { _, _, _, response in
            responses.append(response.json as NSDictionary)
            return responses.count < 3 ? .ownershipLost : .persisted
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A paused response must retain its accepted intent")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        for attempt in 1...2 {
            await waitForState(fixture.coordinator, .paused)
            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(responses.count, attempt)
            XCTAssertTrue(fixture.coordinator.canReactivate)
            fixture.coordinator.reject()
            XCTAssertTrue(fixture.coordinator.isPaused)
            fixture.coordinator.retryRecovery()
            XCTAssertEqual(fixture.coordinator.phase, .responding)
        }
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(responses.count, 3)
        XCTAssertTrue(responses.allSatisfy { $0 == responses[0] })
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testApprovalFinalizesImmediatelyWithFreshSnapshotAndExactAuthorization() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        let finalizer = AsyncGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization started without a timer")
        var snapshots = [ExtensionBridge.Snapshot]()
        var authorizations = [ExtensionBridge.NativeApprovalAuthorization]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime }, wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { snapshot, authorization in
                snapshots.append(snapshot)
                authorizations.append(authorization)
                started.fulfill()
                return await finalizer.run()
            }
        ))
        defer { waits.resumeAll() }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Accepted approval cannot become rejection")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        let approvedAt = clock.now.addingTimeInterval(2)
        clock.now = approvedAt
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: fixture.key.nativeDeliveryNonce,
            owner: nativeOwner(runtime: fixture.runtime)
        )
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle, nonce: fixture.key.nativeDeliveryNonce,
            deadline: clock.now.addingTimeInterval(200), receipt: receipt, sequence: 17
        )
        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator, events = fixture.events] event in
            events.record(event, coordinator: coordinator)
            if case .presentationChanged = event,
               case .waiting? = coordinator?.currentPresentation?.presentation {
                XCTAssertEqual(coordinator?.phase, .waiting)
                coordinator?.approveAccounts([], ethereumNetwork: nil)
                coordinator?.approveAddEthereumChain()
                coordinator?.reject()
            }
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Accepting a decision must synchronously replace review")
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        fixture.coordinator.reject()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.sequence, 17)
        XCTAssertEqual(authorizations.first?.receipt, receipt)
        XCTAssertEqual(authorizations.first?.approvedAt, approvedAt)
        XCTAssertEqual(waits.delays.count, 1)
        XCTAssertTrue(waits.isPending(0))

        var reads = 0
        fixture.store.loadHandler = { _ in reads += 1; return .missing }
        waits.resume(0)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        finalizer.resume(.responseReady)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 3)
        fixture.store.loadHandler = nil
    }

    func testExpiredApprovalCannotInvokeFinalizationBeforeDispatch() async throws {
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _, _ in
            decisions += 1
            return .responseReady
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        let snapshot = try XCTUnwrap(fixture.store.snapshot)
        let deadline = try XCTUnwrap(snapshot.request?.admissionDeadline)
        var reads = 0
        fixture.store.loadHandler = { _ in reads += 1; return .found(snapshot) }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        fixture.clock.now = deadline
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }

    func testSuspendedFinalizationSurvivesCloseAndRecoveryBudget() async throws {
        let finalizer = AsyncGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalizer suspended")
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _, _ in
            decisions += 1
            started.fulfill()
            return await finalizer.run()
        })
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Closing an accepted approval must only dismiss")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close(); _ = agent }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [started], timeout: 1)
        window.close()
        XCTAssertTrue(approval.isDismissed)
        fixture.clock.now.addTimeInterval(11)
        fixture.coordinator.retryRecovery()
        fixture.coordinator.reject()
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        finalizer.resume(.responseReady)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 1)
    }

    func testPendingFinalizationPollsWithBackoffAndRetainsAuthorization() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        var authorizations = [ExtensionBridge.NativeApprovalAuthorization]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime }, wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, authorization in
                authorizations.append(authorization)
                return authorizations.count == 4 ? .responseReady : .pending
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await waitForScheduledWait(waits, count: 2)
        XCTAssertEqual(authorizations.count, 1)
        for index in 1...3 {
            clock.now.addTimeInterval(Double(waits.delays[index]) / 1_000_000_000)
            waits.resume(index)
            if index < 3 { await waitForScheduledWait(waits, count: index + 2) }
        }
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(Array(waits.delays.dropFirst()), [1_000_000_000, 2_000_000_000, 4_000_000_000])
        XCTAssertEqual(authorizations.count, 4)
        XCTAssertEqual(Set(authorizations.map(\.approvedAt)).count, 1)
        XCTAssertTrue(authorizations.allSatisfy { $0.receipt == authorizations[0].receipt })
    }

    func testClaimedExecutionIsObservedWithoutReplayingDecision() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        let finalizer = AsyncGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization started")
        var decisions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime }, wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, _ in
                decisions += 1
                started.fulfill()
                return await finalizer.run()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [started], timeout: 1)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        finalizer.resume(.pending)
        await waitForScheduledWait(waits, count: 2)
        waits.resume(1)
        await waitForScheduledWait(waits, count: 3)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .responded)
        waits.resume(2)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 1)
    }

    func testInterruptionPersistenceRetriesWithoutReplayingApproval() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        var decisions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime }, wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, _ in decisions += 1; return .interruptionRequired }
        ))
        defer { waits.resumeAll() }
        var interruptions = 0
        fixture.store.interruptionHandler = {
            interruptions += 1
            return interruptions < 3 ? .retryablePersistenceFailure : .interrupted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await waitForScheduledWait(waits, count: 2)
        XCTAssertEqual(fixture.coordinator.phase, .rejecting)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        fixture.coordinator.retryRecovery()
        fixture.coordinator.reject()
        waits.resume(1)
        await waitForScheduledWait(waits, count: 3)
        waits.resume(2)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(interruptions, 3)
        guard case .interrupted? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Expected terminal interruption")
        }
        fixture.coordinator.retryRecovery()
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        XCTAssertEqual(decisions, 1)
        XCTAssertFalse(fixture.coordinator.canReactivate)
    }

    func testApprovalLoadOwnershipChangeDoesNotInvokeFinalization() async throws {
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _, _ in
            decisions += 1
            return .responseReady
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        fixture.store.snapshot = try ownedSnapshot(fixture, runtime: UUID())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }

    func testSuspendedApprovalLoadDoesNotRetainCoordinatorOrFinalizeAfterRelease() async throws {
        let load = AsyncGate<ExtensionBridge.SnapshotResult>()
        let started = expectation(description: "approval load suspended")
        var decisions = 0
        var fixture: Fixture? = try makeFixture(attemptNativeDecision: { _, _ in
            decisions += 1
            return .responseReady
        })
        weak var coordinator = fixture?.coordinator
        let events = try XCTUnwrap(fixture?.events)
        let store = try XCTUnwrap(fixture?.store)
        start(try XCTUnwrap(fixture))
        await waitForState(try XCTUnwrap(coordinator), .awaitingAuthentication)
        coordinator?.resumeAfterAuthentication()
        await waitForState(try XCTUnwrap(coordinator), .reviewing)
        let snapshot = try XCTUnwrap(store.snapshot)
        store.loadHandler = { _ in started.fulfill(); return await load.run() }
        coordinator?.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [started], timeout: 1)
        let presentations = events.presentations.count
        fixture = nil
        XCTAssertNil(coordinator)
        load.resume(.found(snapshot))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(events.presentations.count, presentations)
        XCTAssertEqual(store.interruptionCount, 0)
    }

    func testAcceptedResponseIgnoresCloseBetweenRetries() async throws {
        let clock = Clock()
        let waiting = expectation(description: "retry suspended")
        let gate = AsyncGate<Void>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { _ in waiting.fulfill(); await gate.run() },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var responses = 0
        fixture.store.completeHandler = { _, _, _, _ in
            responses += 1
            return responses == 1 ? .retryablePersistenceFailure : .persisted
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A response retry must retain its intent")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [waiting], timeout: 1)
        fixture.coordinator.reject()
        gate.resume(())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(responses, 2)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testAmbiguousResponseCommitWinsOverCancellation() async throws {
        let clock = Clock()
        let writeStarted = expectation(description: "response write in flight")
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
            wait: { _ in await Task.yield() },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        fixture.store.completeHandler = { _, _, _, _ in
            writeStarted.fulfill()
            return await gate.run()
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A durably committed response must win over cancellation")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [writeStarted], timeout: 1)
        fixture.coordinator.reject()
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .responded)
        gate.resume(.retryablePersistenceFailure)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testRetriedRejectionCannotOverlapAnotherClose() async throws {
        let fixture = try makeFixture()
        let started = expectation(description: "retried rejection in flight")
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        var writes = 0
        fixture.store.rejectHandler = { _, _, _ in
            writes += 1
            if writes == 1 {
                fixture.clock.now.addTimeInterval(11)
                return .retryablePersistenceFailure
            }
            started.fulfill()
            return await gate.run()
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .paused)
        fixture.coordinator.retryRecovery()
        await fulfillment(of: [started], timeout: 1)
        fixture.coordinator.reject()
        fixture.coordinator.retryRecovery()
        XCTAssertEqual(writes, 2)
        gate.resume(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testResponseReconciliationStopsWhenReceiptOwnershipChanges() async throws {
        for result in [ExtensionBridge.StoreMutationResult.ownershipLost,
                       .retryablePersistenceFailure] {
            let clock = Clock()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now },
                uptime: { clock.uptime },
                wait: { _ in XCTFail("Foreign ownership must not retry") },
                prepareWithoutWallets: { request in
                    .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
                }
            ))
            let foreign = try ownedSnapshot(fixture, runtime: UUID())
            fixture.store.completeHandler = { _, _, _, _ in
                fixture.store.snapshot = foreign
                return result
            }
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Foreign ownership must not be rejected")
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication()
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(fixture.events.presentations.count, 1)
            guard case .superseded? = fixture.events.presentations.first else {
                return XCTFail("Ownership replacement must supersede local processing")
            }
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }

    func testResponseRecoveryUsesTenSecondBudgetAndFixedCadence() async throws {
        let clock = Clock()
        let started = clock.now
        var delays = [UInt64]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                delays.append(delay)
                clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                await Task.yield()
            },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        var writes = 0
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            return .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Recovery timeout is not rejection")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(clock.now.timeIntervalSince(started), 10)
        XCTAssertEqual(delays, Array(repeating: 1_000_000_000, count: 10))
        XCTAssertEqual(writes, 10)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(writes, 10)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testLateResponseReconciliationRecognizesDurableWork() async throws {
        for phase in [ExtensionBridge.Phase.approving, .responded] {
            let clock = Clock()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now }, uptime: { clock.uptime },
                wait: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) },
                prepareWithoutWallets: { request in
                    .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
                }
            ))
            let committed = try ownedSnapshot(fixture, phase: phase)
            fixture.store.completeHandler = { _, _, _, _ in
                clock.now.addTimeInterval(11)
                fixture.store.snapshot = committed
                return .retryablePersistenceFailure
            }
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Late committed work must not be rejected")
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication()
            await waitForState(fixture.coordinator, .finished)
            XCTAssertFalse(fixture.coordinator.isPaused)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
            fixture.store.snapshot = nil
        }
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
                owner: self.nativeOwner(runtime: runtime)
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
                uptime: { clock.uptime },
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

        XCTAssertEqual(coordinator.phase, .finished)
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
                owner: self.nativeOwner(runtime: runtime)
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
                    owner: self.nativeOwner(runtime: UUID())
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
                uptime: { clock.uptime },
                wait: { _ in
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                },
                prepareWithoutWallets: { _ in
                    .approval(self.accountSelectionAction())
                }
            )
        )
        coordinator.onEvent = { [weak coordinator] event in
            if case .presentationChanged = event,
               case .superseded? = coordinator?.currentPresentation?.presentation { finished.fulfill() }
        }
        guard case .approval = await loadPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected approval")
        }

        coordinator.reject()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertEqual(coordinator.phase, .finished)
    }

    func testBackwardWallClockCannotExtendRecoveryBudget() async throws {
        let clock = Clock()
        let started = clock.uptime
        var writes = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                clock.advanceUptime(Double(delay) / 1_000_000_000)
                clock.now.addTimeInterval(-60)
                await Task.yield()
            },
            prepareWithoutWallets: { request in
                .response(ResponseToExtension(for: request, payload: .error(.userRejected)))
            }
        ))
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            return .retryablePersistenceFailure
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(clock.uptime - started, 10)
        XCTAssertEqual(writes, 10)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testCanceledObservationWaitCannotPollTheNewApprovalState() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        var finalizations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
            wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, _ in
                finalizations += 1
                return .pending
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        let store = fixture.store
        clock.now.addTimeInterval(2)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await waitForState(fixture.coordinator, .waiting)
        await waitForScheduledWait(waits, count: 2)
        var loads = 0
        store.loadHandler = { _ in
            loads += 1
            return store.snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }

        waits.resume(0)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(fixture.events.presentations.count, 2)

        store.snapshot = nil
        waits.resume(1)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(finalizations, 1)
    }

    func testSuspendedObservationDoesNotBlockRetriesOrApplyStaleMetadata() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        let probe = AsyncGate<ExtensionBridge.SnapshotResult>()
        let probeStarted = expectation(description: "observation load suspended")
        var finalizations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
            wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, _ in finalizations += 1; return .pending }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        let originalOrder = fixture.coordinator.order
        let store = fixture.store
        var loads = 0
        store.loadHandler = { _ in
            loads += 1
            if loads == 1 {
                probeStarted.fulfill()
                return await probe.run()
            }
            return store.snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }
        waits.resume(0)
        await fulfillment(of: [probeStarted], timeout: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await waitForScheduledWait(waits, count: 2)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(waits.delays.count, 2)
        waits.resume(1)
        await waitForState(fixture.coordinator, .waiting)
        await waitForScheduledWait(waits, count: 3)
        let stale = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: clock.now.addingTimeInterval(-1),
            host: "stale.example"
        )

        let readsBeforeOldObservationReturns = loads
        probe.resume(.found(stale))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(fixture.coordinator.peer?.title, "wallet.example")
        XCTAssertEqual(fixture.coordinator.order, originalOrder)
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        XCTAssertEqual(finalizations, 2)
        XCTAssertEqual(loads, readsBeforeOldObservationReturns)
        XCTAssertEqual(store.maximumOutstandingWrites, 1)
        XCTAssertEqual(fixture.events.presentations.count, 2)

        store.snapshot = nil
        waits.resume(2)
        await waitForState(fixture.coordinator, .finished)
    }

    func testPendingFinalizerAtDeadlineFinishesWithoutAnotherObservation() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        let finalizer = AsyncGate<NativeApprovalFinalizationResult>()
        let finalizerStarted = expectation(description: "finalizer suspended")
        var finalizations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now },
            uptime: { clock.uptime },
            wait: waits.wait,
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, _ in
                finalizations += 1
                finalizerStarted.fulfill()
                return await finalizer.run()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [finalizerStarted], timeout: 1)
        clock.now.addTimeInterval(301)
        finalizer.resume(.pending)
        await waitForState(fixture.coordinator, .finished)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(waits.delays.count, 1)
        XCTAssertEqual(fixture.events.presentations.count, 3)
        guard case .waiting = fixture.events.presentations[1],
              case .finished = fixture.events.presentations[2] else {
            return XCTFail("The observed decision must enter waiting and finish at expiry")
        }
    }

    func testSuspendedTasksDoNotRetainCoordinator() async throws {
        for suspendLoad in [true, false] {
            let clock = Clock()
            let waits = ScheduledWaits()
            let load = AsyncGate<ExtensionBridge.SnapshotResult>()
            var fixture: Fixture? = try makeFixture(clock: clock, environment: .init(
                now: { clock.now },
                uptime: { clock.uptime },
                wait: waits.wait,
                prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) }
            ))
            weak var coordinator = fixture?.coordinator
            let events = try XCTUnwrap(fixture?.events)
            if suspendLoad {
                let loadStarted = expectation(description: "validation load suspended")
                fixture?.store.loadHandler = { _ in
                    loadStarted.fulfill()
                    return await load.run()
                }
                start(try XCTUnwrap(fixture))
                await fulfillment(of: [loadStarted], timeout: 1)
            } else {
                start(try XCTUnwrap(fixture))
                await waitForState(try XCTUnwrap(coordinator), .awaitingAuthentication)
                coordinator?.resumeAfterAuthentication()
                await waitForState(try XCTUnwrap(coordinator), .reviewing)
                await waitForScheduledWait(waits, count: 1)
            }
            let presentationCount = events.presentations.count
            fixture = nil
            XCTAssertNil(coordinator)
            if suspendLoad { load.resume(.missing) }
            waits.resumeAll()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(events.presentations.count, presentationCount)
        }
    }

    func testSuspendedFinalizerDoesNotRetainCoordinatorOrPresentAfterRelease() async throws {
        for result in [NativeApprovalFinalizationResult.responseReady, .interruptionRequired] {
            let clock = Clock()
            let finalizer = AsyncGate<NativeApprovalFinalizationResult>()
            let started = expectation(description: "finalizer suspended")
            var fixture: Fixture? = try makeFixture(clock: clock, environment: .init(
                now: { clock.now }, uptime: { clock.uptime },
                wait: { _ in await Task.yield() },
                prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
                attemptNativeDecision: { _, _ in started.fulfill(); return await finalizer.run() }
            ))
            weak var coordinator = fixture?.coordinator
            let events = try XCTUnwrap(fixture?.events)
            start(try XCTUnwrap(fixture))
            await waitForState(try XCTUnwrap(coordinator), .awaitingAuthentication)
            coordinator?.resumeAfterAuthentication()
            await waitForState(try XCTUnwrap(coordinator), .reviewing)
            coordinator?.approveAccounts([], ethereumNetwork: nil)
            await fulfillment(of: [started], timeout: 1)
            let count = events.presentations.count
            fixture = nil
            XCTAssertNil(coordinator)
            finalizer.resume(result)
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(events.presentations.count, count)
        }
    }

    func testRuntimeArrivalDuringCancellationCannotCauseUnownedRejection() async throws {
        let fixture = try makeFixture()
        let snapshot = try ownedSnapshot(fixture)
        let gate = AsyncGate<ExtensionBridge.SnapshotResult>()
        let started = expectation(description: "pre-runtime cancellation read")
        fixture.store.loadHandler = { _ in started.fulfill(); return await gate.run() }
        fixture.store.unownedRejectHandler = { _ in
            XCTFail("Missing captured runtime must not downgrade an owned mutation")
            return .persisted
        }
        fixture.coordinator.cancelBeforeAuthentication()
        await fulfillment(of: [started], timeout: 1)
        start(fixture)
        gate.resume(.found(snapshot))
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 0)
        fixture.store.loadHandler = nil
    }

    func testDormantCancellationPreservesRejectionOnForegroundRecovery() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                await Task.yield()
            }
        ))
        fixture.store.loadHandler = { _ in .unavailable }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .paused)
        fixture.store.loadHandler = nil
        start(fixture)
        XCTAssertTrue(fixture.coordinator.isDormant)
        XCTAssertEqual(fixture.store.recordCount, 0)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
    }

    func testDormantEntriesExpireWithoutBlockingInboxCapacity() async throws {
        let clock = Clock()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                await Task.yield()
            }
        ))
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 1)
        XCTAssertTrue(inbox.register(fixture.coordinator))
        fixture.store.loadHandler = { _ in .unavailable }
        start(fixture)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(inbox.dormantCoordinators.count, 1)
        clock.now.addTimeInterval(ExtensionBridge.requestTTL)
        XCTAssertTrue(fixture.coordinator.isExpiredDormant)
        let replacement = try makeFixture(clock: clock)
        XCTAssertTrue(inbox.register(replacement.coordinator))
        XCTAssertEqual(inbox.count, 1)
        XCTAssertNil(inbox.coordinator(for: fixture.key))
    }

    func testFreshReviewAfterRetryFencesTheNextApproval() async throws {
        let clock = Clock()
        var available = false
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                if available { try? await Task.sleep(nanoseconds: 60_000_000_000) }
                else {
                    clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                    await Task.yield()
                }
            },
            prepareWithoutWallets: { _ in nil },
            reloadWallets: { available },
            prepare: { _ in .approval(self.accountSelectionAction()) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .paused)
        let pausedRevision = try XCTUnwrap(fixture.coordinator.currentPresentation?.revision)
        available = true
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        let reviewRevision = try XCTUnwrap(fixture.coordinator.currentPresentation?.revision)
        XCTAssertGreaterThan(reviewRevision, pausedRevision)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        guard case .waiting? = fixture.events.presentations.last else {
            return XCTFail("Approval after a recovered review must immediately fence its UI")
        }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.coordinator.currentPresentation?.revision), reviewRevision)
        await waitForState(fixture.coordinator, .waiting)
        let waitingCount = fixture.events.presentations.filter {
            if case .waiting = $0 { return true }
            return false
        }.count
        XCTAssertEqual(waitingCount, 2)
        fixture.store.snapshot = nil
    }

    func testObservationOutagePausesAfterTenSecondsAndRetriesFreshPreparation() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        var unavailable = false
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                if unavailable {
                    clock.now.addTimeInterval(Double(delay) / 1_000_000_000)
                    await Task.yield()
                } else { await waits.wait(delay) }
            },
            prepareWithoutWallets: { _ in
                preparations += 1
                return .approval(self.accountSelectionAction())
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        var reads = 0
        unavailable = true
        fixture.store.loadHandler = { _ in reads += 1; return .unavailable }
        waits.resume(0)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(clock.uptime, 10)
        let pausedReads = reads
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(reads, pausedReads)
        unavailable = false
        fixture.store.loadHandler = nil
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(fixture.store.recordCount, 1)
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
    }

    func testObservedExecutionWithoutLocalDecisionCannotExecute() async throws {
        let clock = Clock()
        var executions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { _ in await Task.yield() },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
            attemptNativeDecision: { _, _ in executions += 1; return .responseReady }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(fixture.store.interruptionCount, 1)
    }

    func testDismissedWindowRendersLatestRecoverySnapshotWithoutRetrying() async throws {
        let clock = Clock()
        var rejecting = false
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                if rejecting {
                    clock.advanceUptime(Double(delay) / 1_000_000_000)
                    await Task.yield()
                } else {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        let review = window.contentViewController
        var rejections = 0
        fixture.store.rejectHandler = { _, _, _ in
            rejecting = true
            rejections += 1
            return .retryablePersistenceFailure
        }
        window.close()
        window.resetActivationCount()
        await waitForState(fixture.coordinator, .paused)
        XCTAssertTrue(approval.isDismissed)
        XCTAssertTrue(window.contentViewController === review)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.activationCount, 0)
        guard case .retryRequired? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("The coordinator must retain the latest hidden presentation")
        }
        let pausedRejections = rejections
        XCTAssertGreaterThan(pausedRejections, 0)
        agent.restoreOldestRecoverableApproval()
        XCTAssertFalse(approval.isDismissed)
        XCTAssertGreaterThan(window.activationCount, 0)
        XCTAssertEqual(fixture.coordinator.phase, .paused)
        XCTAssertEqual(rejections, pausedRejections)
        let recovery = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertEqual(recovery.okButton.title, Strings.tryAgain)
        fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
        recovery.actionButtonTapped(self)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, pausedRejections + 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testRepeatedDeliveryShowsWaitingDuringInitialLoad() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        let agent = Agent(approvalInbox: inbox)
        fixture.coordinator.onEvent = { [weak agent, weak coordinator = fixture.coordinator] event in
            if case .presentationChanged = event, let coordinator {
                agent?.renderCurrentPresentation(for: coordinator.handle, coordinator: coordinator)
            }
        }
        let snapshot = try XCTUnwrap(fixture.store.snapshot)
        let loadGate = AsyncGate<ExtensionBridge.SnapshotResult>()
        let loadStarted = expectation(description: "initial approval load started")
        fixture.store.loadHandler = { _ in
            loadStarted.fulfill()
            return await loadGate.run()
        }
        defer {
            fixture.coordinator.onEvent = nil
            fixture.store.loadHandler = nil
            fixture.store.snapshot = nil
            loadGate.resume(.missing)
            approval.windowController?.close()
        }
        fixture.coordinator.resumeAfterAuthentication()
        await fulfillment(of: [loadStarted], timeout: 1)
        XCTAssertNil(fixture.coordinator.currentPresentation)
        XCTAssertNil(approval.windowController)

        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle,
            nativeDeliveryNonce: fixture.key.nativeDeliveryNonce
        )
        agent.process(route: route)
        let window = try XCTUnwrap(approval.windowController?.window)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(window.isVisible)
        let waiting = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertFalse(waiting.progressIndicator.isHidden)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Explicit reactivation must publish its waiting presentation")
        }
        let revision = fixture.coordinator.currentPresentation?.revision
        agent.process(route: route)
        XCTAssertTrue(window.contentViewController === waiting)
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)

        fixture.store.loadHandler = nil
        loadGate.resume(.found(snapshot))
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertTrue(approval.windowController?.window === window)
        XCTAssertTrue(window.contentViewController is AccountsListViewController)
    }

    func testRepeatedDeliveryPreservesReviewControllerAndSheet() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, _, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        let review = try XCTUnwrap(window.contentViewController as? AccountsListViewController)
        let selection = try XCTUnwrap(review.accountSelection)
        let revision = fixture.coordinator.currentPresentation?.revision
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: { _ in })
        defer { window.endSheet(sheet); sheet.orderOut(nil) }
        window.resetActivationCount()
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        XCTAssertEqual(window.activationCount, 0)
        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle,
            nativeDeliveryNonce: fixture.key.nativeDeliveryNonce
        )
        agent.process(route: route)
        agent.process(route: route)
        XCTAssertTrue(window.contentViewController === review)
        XCTAssertTrue(review.accountSelection === selection)
        XCTAssertTrue(window.sheets.contains { $0 === sheet })
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)
        XCTAssertEqual(fixture.coordinator.phase, .reviewing)
    }

    func testPresentationSnapshotIsPublishedBeforeNotificationAndDeduplicatesWaiting() async throws {
        let fixture = try makeFixture()
        XCTAssertNil(fixture.coordinator.currentPresentation)
        var snapshots = [NativeApprovalCoordinator.PresentationSnapshot]()
        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator] event in
            guard case .presentationChanged = event else { return }
            guard let snapshot = coordinator?.currentPresentation else {
                return XCTFail("Snapshot must be available before notification")
            }
            XCTAssertGreaterThan(snapshot.revision, snapshots.last?.revision ?? 0)
            snapshots.append(snapshot)
        }
        defer { fixture.coordinator.onEvent = nil }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertNil(fixture.coordinator.currentPresentation)
        fixture.coordinator.resumeAfterAuthentication()
        XCTAssertNil(fixture.coordinator.currentPresentation)
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Accepting the review must synchronously publish waiting")
        }
        await waitForState(fixture.coordinator, .waiting)
        XCTAssertEqual(snapshots.count, 2)
        guard case .approval = snapshots[0].presentation,
              case .waiting = snapshots[1].presentation else {
            return XCTFail("Expected one review and one waiting presentation")
        }
    }

    func testInterruptedPresentationRetainsOnlyVisibleErrorWindow() async throws {
        for dismissed in [false, true] {
            let clock = Clock()
            let waits = ScheduledWaits()
            let finalizer = AsyncGate<NativeApprovalFinalizationResult>()
            let started = expectation(description: "finalizer suspended")
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.now }, uptime: { clock.uptime },
                wait: { await waits.wait($0) },
                prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) },
                attemptNativeDecision: { _, _ in started.fulfill(); return await finalizer.run() }
            ))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            let (agent, approval, window) = try attachApprovalWindow(to: fixture)
            defer {
                fixture.coordinator.onEvent = nil
                waits.resumeAll()
                window.close()
            }
            fixture.coordinator.resumeAfterAuthentication()
            await waitForState(fixture.coordinator, .reviewing)
            let selection = try XCTUnwrap((window.contentViewController as? AccountsListViewController)?.accountSelection)
            await waitForScheduledWait(waits, count: 1)
            var rejections = 0
            fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
            fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
            await fulfillment(of: [started], timeout: 1)
            if dismissed { window.close() }
            let activations = window.activationCount
            finalizer.resume(.interruptionRequired)
            await waitForState(fixture.coordinator, .finished)
            guard case .interrupted? = fixture.coordinator.currentPresentation?.presentation else {
                return XCTFail("Expected a terminal interrupted presentation")
            }
            XCTAssertEqual(window.isVisible, !dismissed)
            if !dismissed {
                let error = try XCTUnwrap(window.contentViewController as? WaitingViewController)
                XCTAssertTrue(error.progressIndicator.isHidden)
                XCTAssertEqual(error.titleLabel.stringValue, Strings.approvalInterrupted)
            }
            XCTAssertFalse(approval.acceptsReviewActions)
            selection.complete(accounts: nil)
            agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            approval.activate()
            XCTAssertEqual(window.activationCount, activations)
            XCTAssertEqual(rejections, 0)
        }
    }

    func testRetiredApprovalFencesRetainedSelectionAndWindowCallbacks() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        let agent = Agent(approvalInbox: inbox)
        let window = TrackingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        approval.windowController = WalletWindowController(window: window)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        let accountsList = try XCTUnwrap(window.contentViewController as? AccountsListViewController)
        let selection = try XCTUnwrap(accountsList.accountSelection)
        let outgoing = ReviewTeardownController()
        var teardowns = 0
        outgoing.onInvalidate = { [weak approval, weak agent] in
            guard let approval else { return XCTFail("The approval must own teardown") }
            teardowns += 1
            agent?.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            XCTAssertFalse(approval.acceptsReviewActions)
            approval.beginReview()
            XCTAssertFalse(approval.acceptsReviewActions)
            XCTAssertNil(approval.beginRenderingCurrentPresentation())
        }
        approval.currentReview?.register(outgoing)
        window.contentViewController = outgoing

        fixture.store.snapshot = nil
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)

        window.resetActivationCount()
        selection.complete(accounts: nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        approval.activate()
        approval.close()
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        await Task.yield()
        XCTAssertEqual(teardowns, 1)
        XCTAssertFalse(approval.acceptsReviewActions)
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(window.activationCount, 0)
        XCTAssertTrue(window.contentViewController === outgoing)
        fixture.store.snapshot = nil
    }

    func testWaitingSurfaceReplacesRetryActionAndSpinnerMode() {
        var retries = 0
        let controller = WaitingViewController.with(
            reason: Strings.somethingWentWrong,
            retryAction: { retries += 1 }, closeCompletion: {}
        )
        _ = controller.view
        XCTAssertTrue(controller.progressIndicator.isHidden)
        XCTAssertEqual(controller.okButton.title, Strings.tryAgain)
        controller.actionButtonTapped(self)
        XCTAssertEqual(retries, 1)
        controller.update(reason: Strings.loading)
        XCTAssertFalse(controller.progressIndicator.isHidden)
        XCTAssertEqual(controller.okButton.title, Strings.ok)
        controller.actionButtonTapped(self)
        XCTAssertEqual(retries, 1)
        controller.update(reason: Strings.approvalInterrupted, isWorking: false)
        XCTAssertTrue(controller.progressIndicator.isHidden)
        XCTAssertEqual(controller.okButton.title, Strings.ok)
    }

    func testClosingUnapprovedRecoveryWindowRejectsTheRequest() async throws {
        let clock = Clock()
        let waits = ScheduledWaits()
        var outage = false
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.now }, uptime: { clock.uptime },
            wait: { delay in
                if outage {
                    clock.advanceUptime(Double(delay) / 1_000_000_000)
                    await Task.yield()
                } else { await waits.wait(delay) }
            },
            prepareWithoutWallets: { _ in .approval(self.accountSelectionAction()) }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        let agent = Agent(approvalInbox: inbox)
        let window = TrackingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSViewController()
        approval.windowController = NSWindowController(window: window)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        approval.beginReview()
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.onEvent = { [weak agent] event in
            if case .presentationChanged = event {
                agent?.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            }
        }
        outage = true
        fixture.store.loadHandler = { _ in .unavailable }
        waits.resume(0)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual((window.contentViewController as? WaitingViewController)?.okButton.title,
                       Strings.tryAgain)
        XCTAssertTrue(fixture.coordinator.canReactivate)
        fixture.store.loadHandler = nil
        var rejections = 0
        fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        fixture.coordinator.onEvent = nil
        window.orderOut(nil)
    }

    func testGenericForegroundReopensDismissedOutstandingApprovalWithoutRetrying() async throws {
        let gate = AsyncGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization in flight")
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _, _ in
            decisions += 1
            started.fulfill()
            return await gate.run()
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        let agent = Agent(approvalInbox: inbox)
        let window = TrackingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSViewController()
        approval.windowController = NSWindowController(window: window)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        approval.beginReview()
        fixture.coordinator.onEvent = { [weak agent] event in
            if case .presentationChanged = event {
                agent?.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            }
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Closing an accepted approval must only dismiss")
            return .persisted
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil)
        await fulfillment(of: [started], timeout: 1)
        window.resetActivationCount()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertTrue(approval.isDismissed)
        agent.restoreOldestRecoverableApproval()
        XCTAssertFalse(approval.isDismissed)
        XCTAssertGreaterThan(window.activationCount, 0)
        let waiting = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertEqual(waiting.okButton.title, Strings.ok)
        XCTAssertFalse(waiting.progressIndicator.isHidden)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        gate.resume(.responseReady)
        await waitForState(fixture.coordinator, .finished)
        fixture.coordinator.onEvent = nil
        window.close()
    }

    func testRepeatedCloseDoesNotRestartPausedRejection() async throws {
        let fixture = try makeFixture()
        var rejections = 0
        fixture.store.rejectHandler = { _, _, _ in
            rejections += 1
            if rejections == 1 {
                fixture.clock.now.addTimeInterval(11)
                return .retryablePersistenceFailure
            }
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication()
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .paused)
        fixture.coordinator.reject()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(rejections, 1)
        XCTAssertTrue(fixture.coordinator.isPaused)
        fixture.coordinator.retryRecovery()
        XCTAssertEqual(fixture.coordinator.phase, .rejecting)
        XCTAssertFalse(fixture.coordinator.canReactivate)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 2)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    func testCanceledReceiptAcquisitionRemainsCanceledAfterRecoveryPauses() async throws {
        let fixture = try makeFixture()
        let gate = AsyncGate<ExtensionBridge.StoreMutationResult>()
        let started = expectation(description: "receipt acquisition in flight")
        fixture.store.recordHandler = { _, _, _ in started.fulfill(); return await gate.run() }
        var rejections = 0
        fixture.store.unownedRejectHandler = { _ in rejections += 1; return .persisted }
        start(fixture)
        await fulfillment(of: [started], timeout: 1)
        fixture.coordinator.cancelBeforeAuthentication()
        fixture.clock.now.addTimeInterval(11)
        fixture.store.recordHandler = nil
        gate.resume(.retryablePersistenceFailure)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(rejections, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }

    private func waitForScheduledWait(
        _ waits: ScheduledWaits,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if waits.delays.count >= count { return }
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(waits.delays.count, count, file: file, line: line)
    }

    private func nativeOwner(runtime: UUID) -> ExtensionBridge.NativeDeliveryOwner {
        .init(
            runtimeInstanceIdentifier: runtime,
            processIdentifier: 42,
            processStartDate: Date(timeIntervalSince1970: 1_800_000_000),
            bundleURL: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
            marketingVersion: "1.0.99",
            buildVersion: "148"
        )!
    }

    @MainActor
    private final class Events {
        var authenticationCount = 0
        var presentations = [NativeApprovalCoordinator.Presentation]()

        func record(_ event: NativeApprovalCoordinator.Event, coordinator: NativeApprovalCoordinator?) {
            switch event {
            case .authenticationRequired: authenticationCount += 1
            case .presentationChanged:
                if let snapshot = coordinator?.currentPresentation {
                    presentations.append(snapshot.presentation)
                }
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
        environment: NativeApprovalCoordinator.Environment? = nil,
        attemptNativeDecision: @escaping (
            ExtensionBridge.Snapshot, ExtensionBridge.NativeApprovalAuthorization
        ) async -> NativeApprovalFinalizationResult = { _, _ in .pending }
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
                uptime: { clock.uptime },
                wait: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) },
                prepareWithoutWallets: { _ in .approval(action) },
                attemptNativeDecision: attemptNativeDecision
            )
        )
        let events = Events()
        coordinator.onEvent = { [weak coordinator] in events.record($0, coordinator: coordinator) }
        return Fixture(
            coordinator: coordinator,
            store: store,
            runtime: UUID(),
            key: key,
            clock: clock,
            events: events
        )
    }

    private func attachApprovalWindow(to fixture: Fixture) throws -> (Agent, Agent.ActiveApproval, TrackingWindow) {
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        let agent = Agent(approvalInbox: inbox)
        let window = TrackingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        approval.windowController = WalletWindowController(window: window)
        fixture.coordinator.onEvent = { [weak agent, weak coordinator = fixture.coordinator, events = fixture.events] event in
            events.record(event, coordinator: coordinator)
            if case .presentationChanged = event, let coordinator {
                agent?.renderCurrentPresentation(for: coordinator.handle, coordinator: coordinator)
            }
        }
        return (agent, approval, window)
    }

    private func start(_ fixture: Fixture) {
        fixture.coordinator.start(
            nativeDeliveryOwner: nativeOwner(runtime: fixture.runtime)
        )
    }

    private func ownedSnapshot(
        _ fixture: Fixture,
        runtime: UUID? = nil,
        phase: ExtensionBridge.Phase = .queued
    ) throws -> ExtensionBridge.Snapshot {
        try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.now.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: fixture.key.nativeDeliveryNonce,
                owner: nativeOwner(runtime: runtime ?? fixture.runtime)
            ),
            phase: phase
        )
    }

    private func waitForState(
        _ coordinator: NativeApprovalCoordinator,
        _ expected: NativeApprovalCoordinator.Phase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if coordinator.phase == expected { return }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.phase, expected, file: file, line: line)
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
            case .presentationChanged:
                if presentation == nil, let snapshot = coordinator?.currentPresentation {
                    presentation = snapshot.presentation
                    ready.fulfill()
                }
            }
        }
        coordinator.start(
            nativeDeliveryOwner: nativeOwner(runtime: runtime)
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

    private func accountSelectionWalletsManager() throws -> WalletsManager {
        typealias Vectors = WalletCoreProxyTestVectors
        let key = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture))
        key.addAccountDerivation(
            address: Vectors.abandonEthereumSecondAddress,
            coin: .ethereum,
            derivation: .custom,
            derivationPath: "m/44'/60'/0'/0/1",
            publicKey: Vectors.abandonEthereumSecondPublicKey,
            extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey
        )
        key.addAccountDerivation(
            address: Vectors.solanaAddressFromPublicKey,
            coin: .solana,
            derivation: .custom,
            derivationPath: "m/44'/501'/0'",
            publicKey: Vectors.solanaAddressPublicKey,
            extendedPublicKey: ""
        )
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "selection-wallet")]
        reader.walletData = ["selection-wallet": try XCTUnwrap(key.exportJSON())]
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        XCTAssertTrue(manager.reloadFromStore())
        XCTAssertEqual(manager.wallets.first?.accounts.count, 3)
        return manager
    }

    private func accountSelectionController(
        manager: WalletsManager,
        mode: NativeAccountSelectionMode?,
        selectedAccounts: Set<SpecificWalletAccount>,
        coinType: WalletCoin? = nil
    ) -> AccountsListViewController {
        let controller = instantiate(AccountsListViewController.self)
        controller.walletsManager = manager
        if let mode {
            controller.accountSelection = NativeAccountSelectionSession(
                action: .init(
                    coinType: coinType,
                    selectedAccounts: selectedAccounts,
                    initiallyConnectedProviders: [],
                    network: Networks.ethereum
                ),
                mode: mode,
                lifetime: NativeApprovalReviewLifetime(),
                completion: { _, _ in }
            )
        }
        controller.loadView()
        return controller
    }

    private func accountSelectionWindow(controller: AccountsListViewController) -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func pressDownArrow(in table: NSTableView, window: NSWindow) throws {
        try pressKey("\u{f701}", keyCode: 125, in: table, window: window)
    }

    private func pressKey(
        _ characters: String,
        keyCode: UInt16,
        in table: NSTableView,
        window: NSWindow,
        isRepeat: Bool = false
    ) throws {
        XCTAssertTrue(window.firstResponder === table)
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
        ))
        NSApp.postEvent(down, atStart: true)
        let keyEvent = try XCTUnwrap(NSApp.nextEvent(
            matching: .keyDown,
            until: Date(timeIntervalSinceNow: 1),
            inMode: .default,
            dequeue: true
        ))
        window.sendEvent(keyEvent)
    }

    private func clickAccountRow(
        _ row: Int,
        endingAt endRow: Int? = nil,
        in controller: AccountsListViewController,
        window: NSWindow
    ) throws {
        let table = try XCTUnwrap(controller.tableView)
        let rowRect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rowRect.minX + 10, y: rowRect.midY), to: nil)
        let endRect = table.rect(ofRow: endRow ?? row)
        let endPoint = table.convert(NSPoint(x: endRect.minX + 10, y: endRect.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        if endRow != nil {
            let drag = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: endPoint,
                modifierFlags: [],
                timestamp: timestamp + 0.005,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1
            ))
            NSApp.postEvent(drag, atStart: true)
        }
        NSApp.postEvent(down, atStart: true)
        let mouseEvent = try XCTUnwrap(NSApp.nextEvent(
            matching: .leftMouseDown,
            until: Date(timeIntervalSinceNow: 1),
            inMode: .default,
            dequeue: true
        ))
        if endRow != nil {
            table.mouseDown(with: mouseEvent)
        } else {
            NSApp.sendEvent(mouseEvent)
        }
        let deadline = Date(timeIntervalSinceNow: 0.05)
        while Date() < deadline,
              let event = NSApp.nextEvent(
                  matching: .any,
                  until: deadline,
                  inMode: .default,
                  dequeue: true
              ) {
            NSApp.sendEvent(event)
        }
    }

    private func approvalSnapshot(
        handle: ExtensionBridge.Handle,
        nonce: ExtensionBridge.NativeDeliveryNonce,
        deadline: Date,
        receipt: ExtensionBridge.NativeDeliveryReceipt? = nil,
        phase: ExtensionBridge.Phase = .queued,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        sequence: Int = 0,
        host: String = "wallet.example"
    ) throws -> ExtensionBridge.Snapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": handle.id,
            "name": "requestAccounts",
            "provider": InpageProvider.ethereum.rawValue,
            "host": host,
            "configurationKey": "https://\(host)",
            "enqueueAttempt": String(format: "%032x", handle.id),
            "admissionDeadline": Int(deadline.timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["address": ""],
        ])
        let request = try XCTUnwrap(SafariRequest(data: data))
        let native: ExtensionBridge.Snapshot.NativeApproval? =
            phase == .approving && receipt != nil
                ? .init(receipt: receipt ?? .init(nativeDeliveryNonce: nonce, owner: nativeOwner(runtime: UUID())),
                        approvedAt: createdAt, executionContext: nil) : nil
        let state: ExtensionBridge.Snapshot.State
        switch phase {
        case .queued:
            state = .queued(
                request: request,
                approval: receipt.map { .delivered($0) } ?? .unowned
            )
        case .approving:
            state = .approving(request: request, nativeApproval: native)
        case .responded:
            state = .responded
        }
        return ExtensionBridge.Snapshot(
            handle: handle,
            state: state,
            nativeDeliveryNonce: nonce,
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

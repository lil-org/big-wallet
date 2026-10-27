import Foundation
import XCTest
import WalletDomain
@testable import WalletAuthority
@testable import WalletFlows
import AppKit
import SwiftUI
@testable import Big_Wallet

@MainActor
final class NativeApprovalCoordinatorTests: XCTestCase {
    func testLateToolbarIntentPreservesTerminalRequestsAndOnlyShowsLockedWallet() async throws {
        for responded in [false, true] {
            for locked in [false, true] {
                let clock = TestClock(uptimeNanoseconds: 0)
                var preparations = 0
                var decisions = 0
                let fixture = try makeFixture(clock: clock, environment: .init(
                    now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                    uptime: { Double(clock.uptimeNanoseconds) / 1_000_000_000 },
                    wait: { _ in try? await TestDeferred<Void>().value() },
                    prepare: { _, _ in preparations += 1; return .unavailable },
                    attemptNativeDecision: { _ in decisions += 1; return .responseReady }
                ))
                fixture.store.snapshot = responded ? try ownedSnapshot(fixture, phase: .responded) : nil
                var writes = 0
                fixture.store.onWrite = { writes += 1 }
                let credentials = authenticationCredentials()
                let access = WalletAccessController(credentials: credentials)
                let generation = access.beginAuthentication(cancel: {})
                let grant = try XCTUnwrap(credentials.verify(password: "test-password", challenge: credentials.makeWalletAccessChallenge()))
                let session = try XCTUnwrap(credentials.accessSession(authorization: grant))
                XCTAssertTrue(access.completeAuthentication(session, generation: generation))
                if locked { access.lock(reason: .idle) }
                var authenticationAttempts = 0
                let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
                    credentials: credentials,
                    attemptBiometrics: { _, _ in authenticationAttempts += 1; return nil }, access: access
                ), makeApprovalCoordinator: { _, _ in fixture.coordinator })
                let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
                defer {
                    fixture.coordinator.onEvent = nil
                    fixture.coordinator.reject()
                    NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
                }
                agent.start(openOnLaunch: false, runtimeIdentity: .init(
                    instanceIdentifier: fixture.runtime, processIdentifier: 42,
                    bundlePath: "/tmp/Big Wallet.app", version: .init(marketing: "1.0.99", build: "148"),
                    workflowVersion: ExtensionBridge.workflowVersion,
                    launchedAt: Date(timeIntervalSince1970: 1_800_000_000)
                ))

                agent.process(route: .toolbarApproval(workflowVersion: ExtensionBridge.workflowVersion,
                    handle: fixture.key.handle, nativeDeliveryNonce: fixture.key.nativeDeliveryNonce))
                await waitForState(fixture.coordinator, .finished)

                let visible = NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible }
                XCTAssertEqual(visible.count, locked ? 1 : 0)
                XCTAssertTrue(visible.allSatisfy { $0.contentViewController is WalletLockedViewController })
                XCTAssertEqual(authenticationAttempts, 0)
                XCTAssertEqual(preparations, 0)
                XCTAssertEqual(decisions, 0)
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(fixture.store.recordCount, 0)
                XCTAssertEqual(fixture.store.snapshot?.phase, responded ? .responded : nil)
                XCTAssertEqual(access.isLocked, locked)
            }
        }
    }

    func testToolbarApprovalRevealsLockedWalletWithoutAuthenticatingAndRejectsTheOldRequest() async throws {
        let fixture = try makeFixture()
        let nextFixture = try makeFixture(key: approvalKey(id: 101))
        let credentials = authenticationCredentials()
        let access = WalletAccessController(credentials: credentials)
        let generation = access.beginAuthentication(cancel: {})
        let grant = try XCTUnwrap(credentials.verify(password: "test-password", challenge: credentials.makeWalletAccessChallenge()))
        let session = try XCTUnwrap(credentials.accessSession(authorization: grant))
        XCTAssertTrue(access.completeAuthentication(session, generation: generation))
        access.lock(reason: .idle)
        var authenticationAttempts = 0
        var rejections = 0
        fixture.store.unownedRejectHandler = { _ in rejections += 1; return .persisted }
        fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
        let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
            credentials: credentials,
            attemptBiometrics: { _, _ in authenticationAttempts += 1; return nil }, access: access
        ), makeApprovalCoordinator: { handle, _ in
            handle == fixture.key.handle ? fixture.coordinator : nextFixture.coordinator
        })
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            fixture.coordinator.onEvent = nil
            fixture.coordinator.reject()
            nextFixture.coordinator.onEvent = nil
            nextFixture.store.rejectHandler = { _, _, _ in .persisted }
            nextFixture.coordinator.reject()
            NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
        }
        agent.start(openOnLaunch: false, runtimeIdentity: .init(
            instanceIdentifier: fixture.runtime, processIdentifier: 42,
            bundlePath: "/tmp/Big Wallet.app", version: .init(marketing: "1.0.99", build: "148"),
            workflowVersion: ExtensionBridge.workflowVersion,
            launchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        XCTAssertTrue(NSApp.windows.allSatisfy { originalWindows.contains(ObjectIdentifier($0)) })

        agent.process(route: .toolbarApproval(workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle, nativeDeliveryNonce: fixture.key.nativeDeliveryNonce))
        await waitForState(fixture.coordinator, .finished)

        let lockedWindow = try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is WalletLockedViewController
        })
        XCTAssertEqual(authenticationAttempts, 0)
        XCTAssertEqual(rejections, 1)
        XCTAssertTrue(access.isLocked)
        XCTAssertFalse(NSApp.windows.contains {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is NativeAccountSelectionViewController
        })
        let locked = try XCTUnwrap(lockedWindow.contentViewController as? WalletLockedViewController)
        locked.unlockWallet()
        await expectEventually {
            NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController }
        }
        let password = try XCTUnwrap(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }
            .compactMap { $0.contentViewController as? PasswordViewController }.first)
        password.passwordTextField.stringValue = "test-password"
        password.actionButtonTapped(password.okButton as Any)
        XCTAssertTrue(access.checkAccess())
        XCTAssertEqual(authenticationAttempts, 1)
        XCTAssertTrue(lockedWindow.contentViewController is AccountsListViewController)

        agent.process(route: .toolbarApproval(workflowVersion: ExtensionBridge.workflowVersion,
            handle: nextFixture.key.handle, nativeDeliveryNonce: nextFixture.key.nativeDeliveryNonce))
        await waitForState(nextFixture.coordinator, .reviewing)
        let visible = NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertEqual(visible.filter { $0.contentViewController is AccountsListViewController }.count, 1)
        XCTAssertEqual(visible.filter { $0.contentViewController is NativeAccountSelectionViewController }.count, 1)
        XCTAssertEqual(authenticationAttempts, 1)
    }

    func testToolbarApprovalWhileUnlockedShowsOnlyItsApprovalWindow() async throws {
        let fixture = try makeFixture()
        let credentials = authenticationCredentials()
        let access = WalletAccessController(credentials: credentials)
        let generation = access.beginAuthentication(cancel: {})
        let grant = try XCTUnwrap(credentials.verify(password: "test-password", challenge: credentials.makeWalletAccessChallenge()))
        let session = try XCTUnwrap(credentials.accessSession(authorization: grant))
        XCTAssertTrue(access.completeAuthentication(session, generation: generation))
        var authenticationAttempts = 0
        let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
            credentials: credentials,
            attemptBiometrics: { _, _ in authenticationAttempts += 1; return nil }, access: access
        ), makeApprovalCoordinator: { _, _ in fixture.coordinator })
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            fixture.coordinator.onEvent = nil
            fixture.store.rejectHandler = { _, _, _ in .persisted }
            fixture.coordinator.reject()
            NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
        }
        agent.start(openOnLaunch: false, runtimeIdentity: .init(
            instanceIdentifier: fixture.runtime, processIdentifier: 42,
            bundlePath: "/tmp/Big Wallet.app", version: .init(marketing: "1.0.99", build: "148"),
            workflowVersion: ExtensionBridge.workflowVersion,
            launchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        agent.process(route: .toolbarApproval(workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle, nativeDeliveryNonce: fixture.key.nativeDeliveryNonce))
        await waitForState(fixture.coordinator, .reviewing)

        let visible = NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertEqual(visible.filter { $0.contentViewController is NativeAccountSelectionViewController }.count, 1)
        XCTAssertFalse(visible.contains { $0.contentViewController is AccountsListViewController || $0.contentViewController is WalletLockedViewController })
        XCTAssertEqual(authenticationAttempts, 0)
    }

    func testOrdinaryApprovalAuthenticationDoesNotOpenWalletManagement() async throws {
        let fixture = try makeFixture()
        let credentials = authenticationCredentials()
        let access = WalletAccessController(credentials: credentials)
        let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
            credentials: credentials, attemptBiometrics: { _, _ in nil }, access: access
        ), makeApprovalCoordinator: { _, _ in fixture.coordinator })
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            fixture.coordinator.onEvent = nil
            fixture.store.rejectHandler = { _, _, _ in .persisted }
            fixture.coordinator.reject()
            NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
        }
        agent.start(openOnLaunch: false, runtimeIdentity: .init(
            instanceIdentifier: fixture.runtime, processIdentifier: 42,
            bundlePath: "/tmp/Big Wallet.app", version: .init(marketing: "1.0.99", build: "148"),
            workflowVersion: ExtensionBridge.workflowVersion,
            launchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        agent.process(route: .approval(workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle, nativeDeliveryNonce: fixture.key.nativeDeliveryNonce))
        await expectEventually {
            NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController }
        }
        let authenticationWindow = try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController
        })
        let password = try XCTUnwrap(authenticationWindow.contentViewController as? PasswordViewController)
        password.passwordTextField.stringValue = "test-password"
        password.actionButtonTapped(password.okButton as Any)
        await waitForState(fixture.coordinator, .reviewing)

        let visible = NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible }
        XCTAssertEqual(visible.filter { $0.contentViewController is NativeAccountSelectionViewController }.count, 1)
        XCTAssertFalse(visible.contains { $0.contentViewController is AccountsListViewController })
        XCTAssertFalse(authenticationWindow.isVisible)
    }

    func testRequestsArrivingWhileLockedRejectWithoutPresentationOrRestartingWrites() async throws {
        for receiptAlreadyOwned in [false, true] {
            let accessFixture = WalletAccessTestFixture()
            try accessFixture.unlock()
            accessFixture.access.lock(reason: .idle)
            let clock = TestClock(uptimeNanoseconds: 0)
            let waits = ScheduledWaits()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { Double(clock.uptimeNanoseconds) / 1_000_000_000 },
                wait: { await waits.wait($0) },
                prepare: { _, _ in XCTFail("Locked requests must not prepare a review"); return .unavailable }
            ))
            if receiptAlreadyOwned { fixture.store.snapshot = try ownedSnapshot(fixture) }
            let firstWrite = TestGate<ExtensionBridge.StoreMutationResult>()
            let writeStarted = expectation(description: "locked rejection started")
            var rejectionCount = 0
            let reject: @MainActor () async -> ExtensionBridge.StoreMutationResult = {
                rejectionCount += 1
                if rejectionCount == 1 {
                    writeStarted.fulfill()
                    return await firstWrite.wait()
                }
                return .persisted
            }
            fixture.store.unownedRejectHandler = { handle in
                XCTAssertFalse(receiptAlreadyOwned)
                XCTAssertEqual(handle, fixture.key.handle)
                return await reject()
            }
            fixture.store.rejectHandler = { handle, nonce, runtime in
                XCTAssertTrue(receiptAlreadyOwned)
                XCTAssertEqual(handle, fixture.key.handle)
                XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
                XCTAssertEqual(runtime, fixture.runtime)
                return await reject()
            }
            var authenticationAttempts = 0
            var creations = 0
            let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
                credentials: accessFixture.credentials,
                attemptBiometrics: { _, _ in authenticationAttempts += 1; return nil },
                access: accessFixture.access
            ), makeApprovalCoordinator: { handle, nonce in
                creations += 1
                XCTAssertEqual(handle, fixture.key.handle)
                XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
                return fixture.coordinator
            })
            let route = NativeAgentRoute.approval(workflowVersion: ExtensionBridge.workflowVersion,
                handle: fixture.key.handle, nativeDeliveryNonce: fixture.key.nativeDeliveryNonce)
            let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let priorKeyWindow = NSApp.keyWindow
            defer {
                fixture.coordinator.onEvent = nil
                fixture.store.unownedRejectHandler = { _ in .ownershipLost }
                fixture.store.rejectHandler = { _, _, _ in .ownershipLost }
                firstWrite.resolve(.persisted)
                waits.resumeAll()
            }

            agent.process(route: route)
            XCTAssertEqual(fixture.coordinator.phase, .registered)
            XCTAssertEqual(rejectionCount, 0)
            agent.start(openOnLaunch: false, runtimeIdentity: .init(
                instanceIdentifier: fixture.runtime, processIdentifier: 42,
                bundlePath: "/tmp/Big Wallet.app", version: .init(marketing: "1.0.99", build: "148"),
                workflowVersion: ExtensionBridge.workflowVersion,
                launchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
            await fulfillment(of: [writeStarted], timeout: 2)
            for _ in 0..<3 { agent.process(route: route) }
            XCTAssertEqual(rejectionCount, 1)
            XCTAssertEqual(fixture.store.outstandingWrites, 1)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)

            firstWrite.resolve(.retryablePersistenceFailure)
            await waitForScheduledWait(waits, count: 1)
            for _ in 0..<3 { agent.process(route: route) }
            XCTAssertEqual(rejectionCount, 1)
            waits.resume(0)
            await waitForState(fixture.coordinator, .finished)

            XCTAssertEqual(rejectionCount, 2)
            XCTAssertEqual(creations, 1)
            XCTAssertEqual(authenticationAttempts, 0)
            XCTAssertEqual(fixture.store.recordCount, 0)
            XCTAssertTrue(NSApp.windows.allSatisfy { priorWindows.contains(ObjectIdentifier($0)) })
            XCTAssertTrue(NSApp.keyWindow === priorKeyWindow)
            XCTAssertTrue(accessFixture.access.isLocked)
        }
    }

    func testExplicitWalletRouteShowsLockedSurfaceWithoutStartingAuthentication() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        fixture.access.lock(reason: .idle)
        var authenticationAttempts = 0
        let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
            credentials: fixture.credentials,
            attemptBiometrics: { _, _ in authenticationAttempts += 1; return nil },
            access: fixture.access
        ))
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))

        agent.process(route: .showWallet(workflowVersion: ExtensionBridge.workflowVersion))

        let window = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is WalletLockedViewController
        })
        defer { window.close() }
        let locked = window.contentViewController
        XCTAssertTrue(window.isVisible)
        for _ in 0..<3 { agent.applicationDidBecomeActive() }
        XCTAssertTrue(window.contentViewController === locked)
        XCTAssertEqual(authenticationAttempts, 0)
        XCTAssertTrue(fixture.access.isLocked)
    }

    func testWalletLockPreservesAcceptedFinalizationWithoutReactivatingItsWindow() async throws {
        for outcome in [NativeApprovalFinalizationResult.responseReady, .reviewRequired] {
            let finalizer = TestGate<NativeApprovalFinalizationResult>()
            let started = expectation(description: "accepted finalization suspended")
            var decisions = 0
            let fixture = try makeFixture(attemptNativeDecision: { _ in
                decisions += 1
                started.fulfill()
                return await finalizer.wait()
            })
            let credentials = authenticationCredentials()
            let access = WalletAccessController(credentials: credentials)
            let generation = access.beginAuthentication(cancel: {})
            let grant = try XCTUnwrap(credentials.verify(password: "test-password", challenge: credentials.makeWalletAccessChallenge()))
            let session = try XCTUnwrap(credentials.accessSession(authorization: grant))
            XCTAssertTrue(access.completeAuthentication(session, generation: generation))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            let (agent, approval, window) = try attachApprovalWindow(to: fixture, access: access, credentials: credentials)
            defer {
                fixture.coordinator.onEvent = nil
                finalizer.resolve(.responseReady)
                window.close()
            }
            fixture.coordinator.resumeAfterAuthentication(authorization: session)
            await waitForState(fixture.coordinator, .reviewing)
            fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: try presentedReview(fixture.coordinator))
            await fulfillment(of: [started], timeout: 1)
            window.resetActivationCount()
            var rejections = 0
            fixture.store.rejectHandler = { _, _, _ in
                rejections += 1
                return .persisted
            }

            access.lock(reason: .idle)

            XCTAssertNil(approval.windowController)
            let locked = try XCTUnwrap(window.contentViewController as? WalletLockedViewController)
            XCTAssertEqual(fixture.coordinator.phase, .waiting)
            XCTAssertEqual(window.activationCount, 0)
            finalizer.resolve(outcome)
            await waitForState(fixture.coordinator, .finished)
            agent.applicationDidBecomeActive()
            agent.restoreOldestRecoverableApproval()
            XCTAssertEqual(decisions, 1)
            XCTAssertEqual(rejections, outcome == .reviewRequired ? 1 : 0)
            XCTAssertEqual(window.activationCount, 0)
            XCTAssertTrue(window.contentViewController === locked)
            XCTAssertTrue(window.isVisible)
        }
    }

    func testFreshReviewKeepsOldSelectionAndPasswordCallbacksInactive() async throws {
        let fixture = try makeFixture(attemptNativeDecision: { _ in .reviewRequired })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        let accounts = try XCTUnwrap(window.contentViewController as? NativeAccountSelectionViewController)
        let selection = try XCTUnwrap(accounts.accountSelection)
        let oldReview = try presentedReview(fixture.coordinator)
        XCTAssertTrue(selection.review === oldReview)
        let windowController = try XCTUnwrap(approval.windowController as? WalletWindowController)
        let credentials = authenticationCredentials()
        let authentication = Task {
            await windowController.authenticate(
                reason: .approveTransaction, challenge: credentials.makeWalletAccessChallenge(), review: oldReview,
                dependencies: .init(credentials: credentials, attemptBiometrics: { _, _ in nil })
            )
        }
        defer { authentication.cancel() }
        await waitForCondition { windowController.currentAuthenticationSession?.sheet?.sheetParent === window }
        let password = try XCTUnwrap(windowController.currentAuthenticationSession?.sheet?.contentViewController as? PasswordViewController)
        XCTAssertTrue(window.contentViewController === accounts)

        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: oldReview)
        await waitForState(fixture.coordinator, .paused)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        let freshReview = try presentedReview(fixture.coordinator)
        let freshController = window.contentViewController
        XCTAssertFalse(oldReview === freshReview)
        XCTAssertFalse(oldReview.isActive)
        XCTAssertTrue(freshReview.isActive)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: oldReview)
        fixture.coordinator.reject(review: oldReview)
        selection.complete(accounts: [])
        password.cancelButtonTapped(password.cancelButton)
        XCTAssertFalse(accounts.responds(to: NSSelectorFromString("didClickImportAccount")))

        let authenticated = await authentication.value
        XCTAssertNil(authenticated)
        XCTAssertNil(windowController.currentAuthenticationSession)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(password.passwordTextField.isEnabled)
        XCTAssertTrue(window.contentViewController === freshController)
        XCTAssertEqual(fixture.coordinator.phase, .reviewing)
        XCTAssertTrue(try presentedReview(fixture.coordinator) === freshReview)
    }


    func testClosingApprovalPasswordTearsDownReviewWithoutAuthenticating() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        let accounts = try XCTUnwrap(window.contentViewController as? NativeAccountSelectionViewController)
        let selection = try XCTUnwrap(accounts.accountSelection)
        let lifetime = try presentedReview(fixture.coordinator)
        let originalController = ReviewTeardownParticipant()
        var cleanupCount = 0
        originalController.onInvalidate = {
            XCTAssertFalse(lifetime.isActive)
            XCTAssertEqual(fixture.coordinator.phase, .rejecting)
            cleanupCount += 1
        }
        lifetime.register(originalController)
        var rejections = 0
        fixture.store.rejectHandler = { _, _, _ in
            rejections += 1
            return .persisted
        }
        let windowController = try XCTUnwrap(approval.windowController as? WalletWindowController)
        var completions = [Bool]()
        let credentials = authenticationCredentials()
        let authentication = Task {
            let result = await windowController.authenticate(
                reason: .approveTransaction, challenge: credentials.makeWalletAccessChallenge(), review: lifetime,
                dependencies: .init(credentials: credentials, attemptBiometrics: { _, _ in nil })
            )
            completions.append(result != nil)
            return result
        }
        defer { authentication.cancel() }
        await waitForCondition { windowController.currentAuthenticationSession?.sheet?.sheetParent === window }
        let password = try XCTUnwrap(windowController.currentAuthenticationSession?.sheet?.contentViewController as? PasswordViewController)

        window.close()
        window.close()
        password.cancelButtonTapped(password.cancelButton)
        selection.complete(accounts: [])
        XCTAssertFalse(accounts.responds(to: NSSelectorFromString("didClickImportAccount")))
        await waitForState(fixture.coordinator, .finished)
        let authenticated = await authentication.value

        XCTAssertFalse(lifetime.isActive)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertNil(authenticated)
        XCTAssertEqual(completions, [false])
        XCTAssertNil(windowController.currentAuthenticationSession)
        XCTAssertFalse(password.passwordTextField.isEnabled)
        XCTAssertEqual(rejections, 1)
    }


    func testClosingOrdinaryPasswordCancelsAuthenticationOnce() async throws {
        var completions = [Bool]()
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let originalController = NSViewController()
        window.contentViewController = originalController
        let windowController = WalletWindowController(window: window)
        window.orderFront(nil)
        let credentials = authenticationCredentials()
        let authentication = Task {
            let result = await windowController.authenticate(
                reason: .approveTransaction, challenge: credentials.makeWalletAccessChallenge(),
                dependencies: .init(credentials: credentials, attemptBiometrics: { _, _ in nil })
            )
            completions.append(result != nil)
            return result
        }
        defer { authentication.cancel(); window.close() }
        await waitForCondition { windowController.currentAuthenticationSession?.sheet?.sheetParent === window }
        let password = try XCTUnwrap(windowController.currentAuthenticationSession?.sheet?.contentViewController as? PasswordViewController)
        XCTAssertTrue(window.contentViewController === originalController)
        window.close()
        window.close()
        password.cancelButtonTapped(password.cancelButton)
        let authenticated = await authentication.value
        XCTAssertNil(authenticated)
        XCTAssertEqual(completions, [false])
        XCTAssertNil(windowController.currentAuthenticationSession)
    }


    func testInitialAuthenticationFailureFallsBackOnlyOnStart() async throws {
        let credentials = authenticationCredentials()
        var events = [StartupCredentialCoordinator.Event]()
        let startup = StartupCredentialCoordinator(
            dependencies: .init(credentials: credentials, attemptBiometrics: { _, _ in .failed }),
            onEvent: { events.append($0) }
        )
        defer { startup.cancel() }
        startup.requestAccess()
        await waitForCondition { startup.windowController?.contentViewController is PasswordViewController }
        XCTAssertTrue(events.isEmpty)
        let password = try XCTUnwrap(startup.windowController?.contentViewController as? PasswordViewController)
        XCTAssertEqual(password.titleLabel.stringValue, Strings.enterPassword)
        startup.cancel()
        XCTAssertEqual(events, [.cancelled])

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let originalController = NSViewController()
        window.contentViewController = originalController
        let windowController = WalletWindowController(window: window)
        window.orderFront(nil)
        defer { window.close() }
        for outcome in [WalletAuthenticationOutcome.failed, .succeeded] {
            let authenticated = await windowController.authenticate(
                reason: .approveTransaction, challenge: credentials.makeWalletAccessChallenge(),
                dependencies: .init(credentials: credentials, attemptBiometrics: { _, challenge in
                    outcome == .succeeded ? .granted(NativeApprovalTestAuthorization.grant(challenge)) : .failed
                })
            )
            XCTAssertEqual(authenticated != nil, outcome == .succeeded)
            authenticated?.invalidate()
            XCTAssertNil(window.attachedSheet)
            XCTAssertNil(windowController.currentAuthenticationSession)
            XCTAssertTrue(window.contentViewController === originalController)
        }
    }


    func testStartupPasswordCanAuthenticateAfterChallengeLifetime() async throws {
        let clock = TestClock()
        let credentials = authenticationCredentials(clock: { clock.date })
        var events = [StartupCredentialCoordinator.Event]()
        let startup = StartupCredentialCoordinator(
            dependencies: .init(credentials: credentials, attemptBiometrics: { _, _ in nil }),
            onEvent: { events.append($0) }
        )
        defer { startup.cancel() }
        startup.requestAccess()
        await waitForCondition { startup.windowController?.contentViewController is PasswordViewController }
        let windowController = try XCTUnwrap(startup.windowController)
        let password = try XCTUnwrap(windowController.contentViewController as? PasswordViewController)

        clock.advance(to: clock.date.addingTimeInterval(151))
        password.passwordTextField.stringValue = "wrong-password"
        password.actionButtonTapped(password.okButton as Any)

        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(startup.accessSession)
        XCTAssertTrue(startup.windowController === windowController)
        XCTAssertTrue(password.passwordTextField.isEnabled)

        clock.advance(to: clock.date.addingTimeInterval(151))
        password.passwordTextField.stringValue = "test-password"
        password.actionButtonTapped(password.okButton as Any)

        XCTAssertEqual(events, [.authenticated])
        XCTAssertTrue(credentials.validateAccess(try XCTUnwrap(startup.accessSession)))
        XCTAssertNil(startup.windowController)
    }


    func testPendingWalletOpenIntentIsConsumedOnce() async {
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


    func testDockOnboardingResolvesAppContainingSafariExtensionHelper() async {
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


    func testDockOnboardingRejectsHelpersOutsideExpectedBundleStructure() async {
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
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        first.store.recordHandler = { _, _, _ in await gate.wait() }
        start(first)
        await waitForState(first.coordinator, .acquiringReceipt)
        XCTAssertFalse(inbox.register(third.coordinator))
        first.store.snapshot = try ownedSnapshot(first)
        gate.resolve(.persisted)
        await waitForState(first.coordinator, .awaitingAuthentication)
        XCTAssertTrue(inbox.register(third.coordinator))
        XCTAssertTrue(inbox.activate("first", for: first.key))
        XCTAssertFalse(inbox.activate("again", for: first.key))
        XCTAssertFalse(inbox.register(first.coordinator))
        XCTAssertEqual(inbox.active(for: first.key), "first")
        XCTAssertTrue(intent.consume())
    }


    func testFailedAuthenticationHandoffReusesActiveApprovalOnRetry() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        let status = LockedTestValue(WalletCredentialIdentity.Status.current)
        let authorityID = NativeApprovalTestAuthorization.authorityID
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID,
            purpose: .walletAccess(UUID()), deadline: .distantFuture)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID,
            credentialIdentity: .init(status: { status.value })))
        let access = try XCTUnwrap(grant.accessSession(authorityID: authorityID))

        status.value = .unavailable
        fixture.coordinator.resumeAfterAuthentication(authorization: access)
        XCTAssertTrue(fixture.coordinator.isAwaitingAuthentication)
        XCTAssertNil(approval.windowController)

        var authenticationAttempts = 0
        let agent = Agent(approvalInbox: inbox, credentialDependencies: .init(
            credentials: authenticationCredentials(),
            attemptBiometrics: { _, challenge in
                authenticationAttempts += 1
                return .granted(NativeApprovalTestAuthorization.grant(challenge))
            }
        ))
        fixture.coordinator.onEvent = { [weak agent, weak coordinator = fixture.coordinator] event in
            if case .presentationChanged = event, let coordinator {
                agent?.renderCurrentPresentation(for: coordinator.handle, coordinator: coordinator)
            }
        }
        defer { fixture.coordinator.onEvent = nil; approval.windowController?.close() }

        agent.start(openOnLaunch: false)
        await waitForState(fixture.coordinator, .reviewing)
        let window = try XCTUnwrap(approval.windowController)
        let review = try presentedReview(fixture.coordinator)
        XCTAssertTrue(window.contentViewController is NativeAccountSelectionViewController)
        agent.process(route: .approval(workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle, nativeDeliveryNonce: fixture.key.nativeDeliveryNonce))
        XCTAssertTrue(approval.windowController === window)
        XCTAssertTrue(try presentedReview(fixture.coordinator) === review)
        XCTAssertEqual(authenticationAttempts, 1)

        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.reject(review: review)
        await waitForState(fixture.coordinator, .finished)
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


    func testAmbientMissingPasswordRejectsApprovalBeforeOnboarding() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        var rejections = 0
        fixture.store.rejectHandler = { _, _, _ in
            rejections += 1
            return .persisted
        }
        var dockLaunches = 0
        let agent = Agent(approvalInbox: inbox, credentialDependencies: .init(
            credentials: authenticationCredentials(password: nil), canCreatePassword: false,
            attemptBiometrics: { _, _ in XCTFail("A missing credential must not authenticate"); return nil },
            openDock: {
                XCTAssertFalse(fixture.coordinator.isAwaitingAuthentication)
                dockLaunches += 1
                return true
            }
        ))
        agent.start(openOnLaunch: false)
        await waitForState(fixture.coordinator, .finished)
        await waitForCondition { dockLaunches == 1 }
        XCTAssertEqual(rejections, 1)

        var events = [StartupCredentialCoordinator.Event]()
        let startup = StartupCredentialCoordinator(
            dependencies: .init(credentials: authenticationCredentials(password: nil), canCreatePassword: true,
                attemptBiometrics: { _, _ in XCTFail("Setup must not authenticate"); return nil },
                openDock: { XCTFail("The dock app owns setup"); return false }),
            onEvent: { events.append($0) }
        )
        defer { startup.cancel() }
        startup.requestAccess()
        XCTAssertTrue(startup.windowController?.contentViewController is WelcomeViewController)
        XCTAssertTrue(events.isEmpty)
    }


    func testFinishedApprovalAlwaysClosesExistingWindow() async {
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


    func testTransactionApprovalDescriptionPreservesMainSummary() async throws {
        let destination = "0x1234567890abcdef1234567890abcdef12345678"
        let chain = try XCTUnwrap(AuthorityTestNetworks.ethereum)
        let transaction = WalletDomain.Transaction(
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


    func testTransactionApprovalDescriptionPreservesContractData() async throws {
        let chain = try XCTUnwrap(AuthorityTestNetworks.ethereum)
        let transaction = WalletDomain.Transaction(
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


    func testApprovalWindowContextSurvivesContentReplacement() async throws {
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


    func testWalletImportPreservesMainLayout() async throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
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


    func testApprovalPasswordPreservesMainLayout() async throws {
        let windowController = try XCTUnwrap(
            NSStoryboard.main.instantiateController(
                withIdentifier: "initial"
            ) as? WalletWindowController
        )
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        let controller = PasswordViewController.with(
            configuration: .init(mode: .enter, reason: .approveTransaction)
        ) { _ in }
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


    func testMessageApprovalRestoresRequesterNameWhenReplacingVisibleContent() async throws {
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
        var outgoingCloses = 0
        let outgoing = WaitingViewController.with(reason: "Waiting") { outgoingCloses += 1 }
        windowController.contentViewController = outgoing
        outgoing.viewDidAppear()
        let controller = ApproveViewController.with(
            subject: .signMessage,
            meta: "Review this message",
            account: account,
            walletId: "appearance-test",
            review: try nativeReviewForTesting(),
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
        let requesterRow = try XCTUnwrap(controller.peerNameLabel.superview as? NSStackView)
        XCTAssertFalse(requesterRow.isHidden)
        XCTAssertEqual(requesterRow.arrangedSubviews.count, 1)
        XCTAssertTrue(requesterRow.arrangedSubviews.first === controller.peerNameLabel)
        XCTAssertEqual(
            try titleTopSpacing(controller.titleLabel, in: controller.view),
            46
        )
        XCTAssertTrue(controller.metaTextView.string.hasSuffix("Review this message"))
        controller.invalidateNativeApprovalReview()
        withExtendedLifetime(outgoing) { window.close() }
        XCTAssertEqual(outgoingCloses, 0)
    }


    func testApprovalHostingSheetPreservesMainContentAndSize() async throws {
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


    func testApprovalAlertPreservesAccessoryAndParentSheet() async throws {
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


    func testOrdinaryHostingSheetPreservesMainContentAndSize() async throws {
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


    func testSuspendedFinalizationSurvivesCloseAndRecoveryBudget() async throws {
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalizer suspended")
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            decisions += 1
            started.fulfill()
            return await finalizer.wait()
        })
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Closing an accepted approval must only dismiss")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close(); _ = agent }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await fulfillment(of: [started], timeout: 1)
        window.close()
        XCTAssertTrue(approval.isDismissed)
        fixture.clock.advance(to: fixture.clock.date.addingTimeInterval(11))
        fixture.coordinator.retryRecovery()
        fixture.coordinator.reject()
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        finalizer.resolve(.responseReady)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 1)
    }


    func testFinalizerInterruptionPublishesRejectingBeforeFirstPersistenceCompletes() async throws {
        let gate = TestGate<ExtensionBridge.NativeInterruptionResult>()
        let started = expectation(description: "interruption persistence suspended")
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            decisions += 1
            return .interruptionRequired
        })
        fixture.store.interruptionHandler = {
            started.fulfill()
            return await gate.wait()
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer {
            fixture.coordinator.onEvent = nil
            window.close()
        }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        let activations = window.activationCount
        await fulfillment(of: [started], timeout: 1)

        XCTAssertEqual(fixture.coordinator.phase, .rejecting)
        XCTAssertEqual(window.activationCount, activations)
        guard case .rejecting? = fixture.coordinator.currentPresentation?.presentation else {
            gate.resolve(.interrupted)
            return XCTFail("Interruption must replace waiting before its first write settles")
        }
        let revision = fixture.coordinator.currentPresentation?.revision
        fixture.coordinator.retryRecovery()
        fixture.coordinator.reject()
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)
        XCTAssertEqual(fixture.store.interruptionCount, 1)
        XCTAssertEqual(decisions, 1)

        gate.resolve(.interrupted)
        await waitForState(fixture.coordinator, .finished)
        guard case .interrupted? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Expected terminal interruption")
        }
        XCTAssertEqual(fixture.store.interruptionCount, 1)
        XCTAssertEqual(decisions, 1)
        XCTAssertFalse(nativeReview.isActive)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        XCTAssertEqual(window.activationCount, activations)
    }


    func testDismissedWindowRendersLatestRecoverySnapshotWithoutRetrying() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var rejecting = false
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                if rejecting {
                    clock.advanceUptime(by: UInt64((Double(delay) / 1_000_000_000) * 1_000_000_000))
                    await Task.yield()
                } else {
                    try? await TestDeferred<Void>().value()
                }
            },
            prepare: { binding, _ in self.approvalPreparation(binding) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
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


    func testAccessibilityRetryRenewsAccessAndRetiredRetryCannotRenewAgain() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let accessClock = TestClock(uptimeNanoseconds: 0)
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { Double(clock.uptimeNanoseconds) / 1_000_000_000 },
            wait: { _ in try? await TestDeferred<Void>().value() },
            prepare: { binding, _ in
                preparations += 1
                if preparations == 1 { return .unavailable }
                return self.approvalPreparation(binding)
            }
        ))
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        let credentials = authenticationCredentials(accessClock: { accessClock.instant })
        let scheduler = WalletAccessTestFixture.Scheduler()
        let access = WalletAccessController(credentials: credentials, schedule: scheduler.schedule,
            activityClock: { accessClock.instant })
        let generation = access.beginAuthentication(cancel: {})
        let grant = try XCTUnwrap(credentials.verify(password: "test-password", challenge: credentials.makeWalletAccessChallenge()))
        let session = try XCTUnwrap(credentials.accessSession(authorization: grant))
        XCTAssertTrue(access.completeAuthentication(session, generation: generation))
        let originalExpiration = try XCTUnwrap(scheduler.expirations.last)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, approval, window) = try attachApprovalWindow(to: fixture, access: access, credentials: credentials)
        defer {
            fixture.coordinator.onEvent = nil
            access.lock(reason: .idle)
            fixture.coordinator.reject()
            window.close()
            withExtendedLifetime(agent) {}
        }
        fixture.coordinator.resumeAfterAuthentication(authorization: session)
        await waitForState(fixture.coordinator, .paused)
        let recovery = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertEqual(recovery.okButton.title, Strings.tryAgain)
        accessClock.advanceUptime(by: 899_000_000_000)
        let beforeRetry = scheduler.expirations.count

        _ = recovery.okButton.accessibilityPerformPress()

        XCTAssertEqual(scheduler.expirations.count, beforeRetry + 1)
        XCTAssertTrue(originalExpiration.cancelled)
        XCTAssertEqual(credentials.remainingAccessLifetime(session), .seconds(900))
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(preparations, 2)
        accessClock.advanceUptime(by: 2_000_000_000)
        originalExpiration.action()
        XCTAssertTrue(access.checkAccess())
        XCTAssertEqual(credentials.remainingAccessLifetime(session), .seconds(898))
        XCTAssertEqual(fixture.coordinator.phase, .reviewing)

        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertTrue(approval.isRetired)
        let afterRetirement = scheduler.expirations.count
        recovery.actionButtonTapped(self)
        XCTAssertEqual(scheduler.expirations.count, afterRetirement)
        XCTAssertTrue(access.checkAccess())

        access.lock(reason: .systemSleep)
        let afterLock = scheduler.expirations.count
        recovery.actionButtonTapped(self)
        XCTAssertEqual(scheduler.expirations.count, afterLock)
        XCTAssertTrue(access.isLocked)

        let replacementGeneration = access.beginAuthentication(cancel: {})
        let replacementGrant = try XCTUnwrap(credentials.verify(password: "test-password", challenge: credentials.makeWalletAccessChallenge()))
        let replacement = try XCTUnwrap(credentials.accessSession(authorization: replacementGrant))
        XCTAssertTrue(access.completeAuthentication(replacement, generation: replacementGeneration))
        let afterUnlock = scheduler.expirations.count
        recovery.actionButtonTapped(self)
        XCTAssertEqual(scheduler.expirations.count, afterUnlock)
        XCTAssertTrue(access.session === replacement)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(fixture.coordinator.phase, .finished)
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
        let loadGate = TestGate<ExtensionBridge.SnapshotResult>()
        let loadStarted = expectation(description: "initial approval load started")
        fixture.store.loadHandler = { _ in
            loadStarted.fulfill()
            return await loadGate.wait()
        }
        defer {
            fixture.coordinator.onEvent = nil
            fixture.store.loadHandler = nil
            fixture.store.snapshot = nil
            loadGate.resolve(.missing)
            approval.windowController?.close()
        }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await fulfillment(of: [loadStarted], timeout: 1)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Loading must publish waiting without opening a window")
        }
        let revision = fixture.coordinator.currentPresentation?.revision
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
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)
        agent.process(route: route)
        XCTAssertTrue(window.contentViewController === waiting)
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)

        fixture.store.loadHandler = nil
        loadGate.resolve(.found(snapshot))
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertTrue(approval.windowController?.window === window)
        XCTAssertTrue(window.contentViewController is NativeAccountSelectionViewController)
    }


    func testRepeatedDeliveryShowsWaitingDuringSilentResponsePersistence() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("The pending write must settle before recovery") },
            prepare: { request, _ in
                preparations += 1
                return .immediate(.failure(.userRejected))
            }))
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        let started = expectation(description: "silent response persistence")
        var writes = 0
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            started.fulfill()
            return await gate.wait()
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("An accepted response cannot be replaced by rejection")
            return .persisted
        }
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
        defer {
            withExtendedLifetime(agent) {
                fixture.coordinator.onEvent = nil
                gate.resolve(.persisted)
                approval.windowController?.close()
            }
        }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(fixture.coordinator.phase, .responding)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Response persistence must publish waiting without opening a window")
        }
        let revision = fixture.coordinator.currentPresentation?.revision
        XCTAssertNil(approval.windowController)

        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: fixture.key.handle,
            nativeDeliveryNonce: fixture.key.nativeDeliveryNonce
        )
        let window = TrackingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        approval.windowController = WalletWindowController(window: window)
        XCTAssertFalse(window.isVisible)
        agent.process(route: route)
        let waiting = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertTrue(window.isVisible)
        XCTAssertGreaterThan(window.activationCount, 0)
        XCTAssertFalse(waiting.progressIndicator.isHidden)
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)
        agent.process(route: route)
        fixture.coordinator.retryRecovery()
        XCTAssertTrue(window.contentViewController === waiting)
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(writes, 1)

        gate.resolve(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(window.closeCount, 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testImmediateResponseFinishesWithoutCreatingApprovalWindow() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("An immediate response must not poll") },
            prepare: { request, _ in
                .immediate(.failure(.userRejected))
            }))
        var writes = 0
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            return .persisted
        }
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
                XCTAssertNil(approval.windowController)
            }
        }
        defer { fixture.coordinator.onEvent = nil }

        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(writes, 1)
        XCTAssertNil(approval.windowController)
        XCTAssertNil(approval.beginRenderingCurrentPresentation(allowNewWaitingWindow: true))
        agent.renderCurrentPresentation(
            for: fixture.key.handle,
            coordinator: fixture.coordinator,
            allowNewWaitingWindow: true
        )
        XCTAssertNil(approval.windowController)
    }


    func testRepeatedDeliveryPreservesReviewControllerAndSheet() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let (agent, _, window) = try attachApprovalWindow(to: fixture)
        defer { fixture.coordinator.onEvent = nil; window.close() }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let review = try XCTUnwrap(window.contentViewController as? NativeAccountSelectionViewController)
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


    func testInterruptedPresentationRetainsOnlyVisibleErrorWindow() async throws {
        for dismissed in [false, true] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let waits = ScheduledWaits()
            let finalizer = TestGate<NativeApprovalFinalizationResult>()
            let started = expectation(description: "finalizer suspended")
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { await waits.wait($0) },
                prepare: { binding, _ in self.approvalPreparation(binding) },
                attemptNativeDecision: { _ in started.fulfill(); return await finalizer.wait() }
            ))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            let (agent, approval, window) = try attachApprovalWindow(to: fixture)
            defer {
                fixture.coordinator.onEvent = nil
                waits.resumeAll()
                window.close()
            }
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await waitForState(fixture.coordinator, .reviewing)
            let nativeReview = try presentedReview(fixture.coordinator)
            let selection = try XCTUnwrap((window.contentViewController as? NativeAccountSelectionViewController)?.accountSelection)
            await waitForScheduledWait(waits, count: 1)
            var rejections = 0
            fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
            fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
            await fulfillment(of: [started], timeout: 1)
            if dismissed { window.close() }
            let activations = window.activationCount
            finalizer.resolve(.interruptionRequired)
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
            XCTAssertFalse(nativeReview.isActive)
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
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        let accountsList = try XCTUnwrap(window.contentViewController as? NativeAccountSelectionViewController)
        let selection = try XCTUnwrap(accountsList.accountSelection)
        let outgoing = ReviewTeardownParticipant()
        var teardowns = 0
        outgoing.onInvalidate = { [weak approval, weak agent] in
            guard let approval else { return XCTFail("The approval must own teardown") }
            teardowns += 1
            agent?.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            XCTAssertFalse(nativeReview.isActive)
            fixture.coordinator.reject(review: nativeReview)
            XCTAssertNil(approval.beginRenderingCurrentPresentation())
        }
        nativeReview.register(outgoing)
        window.contentViewController = NSViewController()

        fixture.store.snapshot = nil
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)

        window.resetActivationCount()
        selection.complete(accounts: nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        approval.activate()
        agent.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
        XCTAssertEqual(teardowns, 1)
        XCTAssertFalse(nativeReview.isActive)
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(window.activationCount, 0)
        XCTAssertTrue(window.contentViewController is WaitingViewController)
        fixture.store.snapshot = nil
    }


    func testWaitingSurfaceReplacesRetryActionAndSpinnerMode() async {
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
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let outage = LockedTestValue(false)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                if outage.value {
                    clock.advanceUptime(by: UInt64((Double(delay) / 1_000_000_000) * 1_000_000_000))
                    await Task.yield()
                } else { await waits.wait(delay) }
            },
            prepare: { binding, _ in self.approvalPreparation(binding) }
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
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.onEvent = { [weak agent] event in
            if case .presentationChanged = event {
                agent?.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            }
        }
        outage.value = true
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
        let gate = TestGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization in flight")
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            decisions += 1
            started.fulfill()
            return await gate.wait()
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
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.onEvent = { [weak agent] event in
            if case .presentationChanged = event {
                agent?.renderCurrentPresentation(for: fixture.key.handle, coordinator: fixture.coordinator)
            }
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Closing an accepted approval must only dismiss")
            return .persisted
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
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
        gate.resolve(.responseReady)
        await waitForState(fixture.coordinator, .finished)
        fixture.coordinator.onEvent = nil
        window.close()
    }


    final class TrackingWindow: NSWindow {
        private(set) var activationCount = 0
        private(set) var deminiaturizationCount = 0
        private(set) var closeCount = 0

        override func deminiaturize(_ sender: Any?) {
            deminiaturizationCount += 1
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            activationCount += 1
            super.makeKeyAndOrderFront(sender)
        }

        override func close() {
            closeCount += 1
            super.close()
        }

        func resetActivationCount() {
            activationCount = 0
        }
    }


    func authenticationCredentials(
        password: String? = "test-password", clock: @escaping @Sendable () -> Date = Date.init,
        accessClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> WalletCredentials {
        let reader = KeychainCopyMatchingStub()
        reader.passwordData = password.map { Data($0.utf8) }
        return WalletCredentials(keychain: Keychain(copyMatching: reader.copyMatching), messages: .testingEnglish,
            authorityID: NativeApprovalTestAuthorization.authorityID, clock: clock, accessClock: accessClock)
    }


    func attachApprovalWindow(to fixture: Fixture, access: WalletAccessController? = nil, credentials: WalletCredentials? = nil) throws -> (Agent, Agent.ActiveApproval, TrackingWindow) {
        let approval = Agent.ActiveApproval(coordinator: fixture.coordinator, access: access)
        var inbox = ApprovalInbox<Agent.ActiveApproval>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        XCTAssertTrue(inbox.activate(approval, for: fixture.key))
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.access = access
        if let credentials { dependencies.credentials = credentials }
        let agent = Agent(approvalInbox: inbox, credentialDependencies: dependencies)
        let window = TrackingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let controller = WalletWindowController(window: window)
        controller.bindAccess(access, unlock: {})
        approval.windowController = controller
        fixture.coordinator.onEvent = { [weak agent, weak coordinator = fixture.coordinator, events = fixture.events] event in
            events.record(event, coordinator: coordinator)
            if case .presentationChanged = event, let coordinator {
                agent?.renderCurrentPresentation(for: coordinator.handle, coordinator: coordinator)
            }
        }
        return (agent, approval, window)
    }


    func titleTopSpacing(
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

}

// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private let popupNativeDeliveryOwner = ExtensionBridge.NativeDeliveryOwner(
    bundleURL: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
    marketingVersion: "1.0.99",
    buildVersion: "148"
)!

private let popupRequestAdmissionDeadline = 2_000_000_900_000

private enum PopupRequestSessionsTestError: Error {
    case timedOut
}

@MainActor
final class PopupRequestSessionsTests: XCTestCase {

    func testSourceWalletEnvironmentReloadsAfterFailedInitialStart() {
        var events = [String]()
        let environment = SourcePopupWalletEnvironment(
            startWalletsManager: {
                events.append("start")
                return false
            },
            reloadWalletsManager: {
                events.append("reload")
                return true
            }
        )

        XCTAssertNil(environment.prepareForNewSession())
        XCTAssertNotNil(environment.prepareForNewSession())
        XCTAssertEqual(events, ["start", "reload"])
    }

    func testSessionUsesFourDisposablePhasesAndOneReviewToken() throws {
        let session = try makeSession()
        let initialToken = session.reviewToken

        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertEqual(session.state, .working)
        XCTAssertNotEqual(token, initialToken)

        let claim = ExtensionBridge.ApprovalClaim(
            handle: session.handle,
            value: UUID()
        )
        XCTAssertNil(session.approvalClaim)
        XCTAssertFalse(session.beginAuthentication(claim: claim, token: token))
        XCTAssertTrue(session.acceptClaim(claim, token: token))
        XCTAssertEqual(session.approvalClaim, claim)
        XCTAssertTrue(session.beginAuthentication(claim: claim, token: token))
        XCTAssertEqual(session.state, .authenticating)
        XCTAssertTrue(session.finishAuthentication(claim: claim, token: token))
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertEqual(session.state, .review)
        XCTAssertNil(session.approvalClaim)

        session.fail("Unavailable")
        XCTAssertEqual(session.state, .error)
        session.retry()
        XCTAssertEqual(session.state, .review)
        XCTAssertNotEqual(session.reviewToken, token)
    }

    func testStaleReviewTokenCannotMutateSession() throws {
        let session = try makeSession()
        let token = try XCTUnwrap(session.beginApproval())
        let stale = UUID()
        let claim = ExtensionBridge.ApprovalClaim(
            handle: session.handle,
            value: UUID()
        )

        XCTAssertFalse(session.acceptClaim(claim, token: stale))
        XCTAssertTrue(session.acceptClaim(claim, token: token))
        XCTAssertFalse(session.beginAuthentication(claim: claim, token: stale))
        session.fail("stale", token: stale)
        XCTAssertEqual(session.state, .working)
    }

    func testMaterialReviewChangesRotateTheSingleReviewToken() throws {
        let session = try makeSession()
        let first = session.reviewToken
        let firstRevision = session.presentationRevision
        session.rotateReviewToken()
        XCTAssertNotEqual(session.reviewToken, first)
        XCTAssertEqual(session.presentationRevision, firstRevision + 1)

        let active = try XCTUnwrap(session.beginApproval())
        session.rotateReviewToken()
        XCTAssertEqual(session.reviewToken, active)
        XCTAssertEqual(session.presentationRevision, firstRevision + 2)
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        XCTAssertTrue(source.contains("case .snapshot, .verifiedFeeEstimate, .editorRequest:"))
        XCTAssertTrue(source.contains("case .alert:"))
    }

    func testSessionPreservesFeedbackAndRecoveryAcrossAuthentication() throws {
        let session = try makeSession()
        session.setFeedback("Choose an account")
        XCTAssertEqual(session.errorText, "Choose an account")
        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertNil(session.errorText)
        let claim = ExtensionBridge.ApprovalClaim(
            handle: session.handle,
            value: UUID()
        )
        XCTAssertTrue(session.acceptClaim(claim, token: token))
        session.setFeedback("Try again")
        XCTAssertTrue(session.beginAuthentication(claim: claim, token: token))
        XCTAssertEqual(session.errorText, "Try again")
        session.requireRematerializationAfterAuthentication()
        XCTAssertTrue(session.finishAuthentication(claim: claim, token: token))
        XCTAssertTrue(session.takeAuthenticationRematerializationRequirement())
        XCTAssertFalse(session.takeAuthenticationRematerializationRequirement())
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertEqual(session.errorText, "Try again")
        XCTAssertNil(session.approvalClaim)
        XCTAssertEqual(session.reviewToken, token)
        session.retry()
        XCTAssertNil(session.errorText)
        XCTAssertNotEqual(session.reviewToken, token)
    }

    func testSessionCanReturnToReviewFromUnclaimedAndFailedAttempts() throws {
        let session = try makeSession()
        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertEqual(session.state, .review)
        session.fail("Unavailable", token: token)
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertEqual(session.errorText, "Unavailable")
        XCTAssertNil(session.approvalClaim)
    }

    func testImmediateResponseSessionStartsWorkingWithoutApprovalAuthority() throws {
        let snapshot = try popupSnapshot(id: 475)
        let session = PopupRequestSession(
            handle: snapshot.handle,
            request: try XCTUnwrap(snapshot.request),
            purpose: .immediateResponsePersistence
        )
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.isImmediateResponsePersistence)
        XCTAssertNil(session.approvalClaim)
        XCTAssertNil(session.approvalAction)
        XCTAssertNil(session.beginApproval())
        XCTAssertNil(session.errorText)
        session.fail("Unavailable")
        XCTAssertEqual(session.state, .error)
        XCTAssertEqual(session.errorText, "Unavailable")
    }

    func testNativeControllerHasNoDurableCoordinatorOrRetryEngine() throws {
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        XCTAssertFalse(source.contains("PopupDurableApprovalCoordinator"))
        XCTAssertFalse(source.contains("DeferredReply"))
        XCTAssertFalse(source.contains("watchdog"))
        XCTAssertFalse(source.contains("retryScheduler"))
    }

    func testTransactionBroadcastIsCheckpointedBeforeSend() throws {
        let source = try source(named: "Safari Shared/DurableApprovalExecutor.swift")
        let checkpoint = try XCTUnwrap(source.range(of: "store.prepareBroadcast"))
        let send = try XCTUnwrap(source.range(of: "prepared.send()"))
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: checkpoint.lowerBound),
            source.distance(from: source.startIndex, to: send.lowerBound)
        )
    }

    func testMobileDeadlineRollsBackAtEveryExactPrecommitBoundary()
        async throws {
        enum Boundary: CaseIterable, Equatable {
            case postValidation, responseCompletion, broadcastCheckpoint
        }

        for (index, boundary) in Boundary.allCases.enumerated() {
            let clock = CompactExecutionClock(
                Date(timeIntervalSince1970: 1_700_000_000)
            )
            let store = CompactPopupStore(clock: { clock.now })
            let snapshot = try popupSnapshot(id: 450 + index)
            await store.insert(snapshot)
            guard case .claimed(let claim) = await store.claim(
                      handle: snapshot.handle
                  ) else {
                return XCTFail("Expected claim")
            }
            let deadline = clock.now.addingTimeInterval(1)
            let executor = DurableApprovalExecutor(
                store: store,
                clock: { clock.now }
            )
            let response = try XCTUnwrap(snapshot.request).response(
                error: .internalError
            )

            if boundary == .responseCompletion {
                await store.setPermitCompletionHook { clock.now = deadline }
            }
            if boundary == .broadcastCheckpoint {
                await store.setBroadcastCheckpointHook { clock.now = deadline }
            }
            let result = await executor.executeSigning(
                claim: claim,
                deadline: deadline,
                acquireWalletLease: {
                    if boundary == .postValidation { clock.now = deadline }
                    return WalletExecutionLease()
                }
            ) {
                if boundary == .broadcastCheckpoint {
                    return .broadcast(PreparedBroadcast(
                        recoveryResponse: response,
                        send: {
                            XCTFail("Expired broadcast must not be sent")
                            return response
                        }
                    ))
                }
                return .response(response)
            }

            XCTAssertEqual(result, .rolledBack)
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "begin", "rollback"])
        }
    }

    func testBroadcastStillSendsWhenDeadlineExpiresAfterCheckpoint()
        async throws {
        let clock = CompactExecutionClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = CompactPopupStore(clock: { clock.now })
        let snapshot = try popupSnapshot(id: 455)
        await store.insert(snapshot)
        guard case .claimed(let claim) = await store.claim(
                  handle: snapshot.handle
              ) else {
            return XCTFail("Expected claim")
        }
        let deadline = clock.now.addingTimeInterval(1)
        let executor = DurableApprovalExecutor(
            store: store,
            clock: { clock.now }
        )
        let request = try XCTUnwrap(snapshot.request)
        let result = await executor.executeSigning(
            claim: claim,
            deadline: deadline,
            acquireWalletLease: {
                WalletExecutionLease { clock.now = deadline }
            }
        ) {
            .broadcast(PreparedBroadcast(
                recoveryResponse: request.response(error: .internalError),
                send: {
                    await store.record("send")
                    return request.response(error: .userRejected)
                }
            ))
        }

        XCTAssertEqual(result, .persisted)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "begin", "checkpoint", "send", "complete"])
        let completedErrorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        XCTAssertEqual(completedErrorCode, ProviderResponseError.userRejected.code)
    }

    func testExecutionLeaseCoversDurableCommitAndEndsBeforeBroadcast()
        async throws {
        for broadcasts in [false, true] {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: broadcasts ? 454 : 453)
            await store.insert(snapshot)
            guard case .claimed(let claim) = await store.claim(
                      handle: snapshot.handle
                  ) else {
                return XCTFail("Expected claim")
            }
            let state = CompactExecutionLeaseState()
            await store.setPermitCompletionHook {
                state.observeDurableCommit()
            }
            await store.setBroadcastCheckpointHook {
                state.observeDurableCommit()
            }
            let response = try XCTUnwrap(snapshot.request).response(
                error: .internalError
            )
            let executor = DurableApprovalExecutor(store: store)

            let result = await executor.executeSigning(
                claim: claim,
                deadline: Date().addingTimeInterval(60),
                acquireWalletLease: {
                    WalletExecutionLease {
                        state.release()
                    }
                }
            ) {
                guard broadcasts else { return .response(response) }
                return .broadcast(PreparedBroadcast(
                    recoveryResponse: response,
                    send: {
                        state.observeBroadcast()
                        return response
                    }
                ))
            }

            XCTAssertEqual(result, .persisted)
            XCTAssertTrue(state.wasHeldAtDurableCommit)
            XCTAssertTrue(state.isReleased)
            if broadcasts {
                XCTAssertTrue(state.wasReleasedBeforeBroadcast)
            }
        }
    }

    func testOperationTimeoutReturnsBeforeUncooperativeWorkAndNeverSendsLateBroadcast() async throws {
        let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = CompactPopupStore(clock: { clock.now })
        let snapshot = try popupSnapshot(id: 456)
        await store.insert(snapshot)
        guard case .claimed(let claim) = await store.claim(handle: snapshot.handle) else {
            return XCTFail("Expected claim")
        }
        let executor = DurableApprovalExecutor(store: store, clock: { clock.now })
        let response = try XCTUnwrap(snapshot.request).response(error: .internalError)
        let gate = CompactPopupGate()
        let finished = expectation(description: "timed out before gate opened")
        let late = expectation(description: "late operation returned")
        var result: DurableApprovalExecutor.Result?
        var leases = 0
        let task = Task { @MainActor in
            result = await executor.executeSigning(
                claim: claim,
                deadline: clock.now.addingTimeInterval(0.01),
                acquireWalletLease: {
                    leases += 1
                    return WalletExecutionLease()
                }
            ) {
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                late.fulfill()
                return .broadcast(PreparedBroadcast(recoveryResponse: response, send: {
                    XCTFail("Late prepared broadcast must not send")
                    return response
                }))
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(result, .rolledBack)
        XCTAssertEqual(leases, 0)
        let eventsBeforeRelease = await store.events()
        XCTAssertEqual(eventsBeforeRelease, ["claim", "begin", "rollback"])
        await gate.open()
        await task.value
        await fulfillment(of: [late], timeout: 1)
        let finalEvents = await store.events()
        XCTAssertEqual(finalEvents, eventsBeforeRelease)
    }

    func testExpiredOperationDeadlineNeverStartsWorkOrAcquiresLease() async throws {
        for offset in [0.0, -1.0] {
            let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
            let store = CompactPopupStore(clock: { clock.now })
            let snapshot = try popupSnapshot(id: 457)
            await store.insert(snapshot)
            guard case .claimed(let claim) = await store.claim(handle: snapshot.handle) else {
                return XCTFail("Expected claim")
            }
            let executor = DurableApprovalExecutor(store: store, clock: { clock.now })
            let response = try XCTUnwrap(snapshot.request).response(error: .internalError)
            let result = await executor.executeSigning(
                claim: claim,
                deadline: clock.now.addingTimeInterval(offset),
                acquireWalletLease: {
                    XCTFail("Expired operation must not acquire a lease")
                    return nil
                }
            ) {
                XCTFail("Expired operation must not start")
                return .response(response)
            }
            XCTAssertEqual(result, .rolledBack)
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "begin", "rollback"])
        }
    }

    func testCallerCancellationDoesNotAbortStartedDurableOperation() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 458)
        await store.insert(snapshot)
        guard case .claimed(let claim) = await store.claim(handle: snapshot.handle) else {
            return XCTFail("Expected claim")
        }
        let executor = DurableApprovalExecutor(store: store)
        let response = try XCTUnwrap(snapshot.request).response(error: .userRejected)
        let gate = CompactPopupGate()
        let started = expectation(description: "operation started")
        let task = Task { @MainActor in
            await executor.executeSigning(
                claim: claim,
                deadline: Date().addingTimeInterval(60),
                acquireWalletLease: { WalletExecutionLease() }
            ) {
                started.fulfill()
                await gate.wait()
                XCTAssertFalse(Task.isCancelled)
                return .response(response)
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.open()
        let result = await task.value
        XCTAssertEqual(result, .persisted)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "begin", "complete"])
    }

    func testZeroBroadcastTimeoutPersistsRecoveryOnceDespiteLateSend() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 459)
        await store.insert(snapshot)
        guard case .claimed(let claim) = await store.claim(handle: snapshot.handle) else {
            return XCTFail("Expected claim")
        }
        let request = try XCTUnwrap(snapshot.request)
        let executor = DurableApprovalExecutor(store: store, broadcastTimeoutNanoseconds: 0)
        let gate = CompactPopupGate()
        let finished = expectation(description: "zero timeout recovery")
        let late = expectation(description: "late broadcast result")
        let task = Task { @MainActor in
            let result = await executor.executeOrdinary(claim: claim) {
                .broadcast(PreparedBroadcast(
                    recoveryResponse: request.response(error: .internalError),
                    send: {
                        await store.record("send")
                        await gate.wait()
                        late.fulfill()
                        return request.response(error: .userRejected)
                    }
                ))
            }
            XCTAssertEqual(result, .persisted)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        let before = await store.completedErrorCode(handle: snapshot.handle)
        XCTAssertEqual(before, ProviderResponseError.internalErrorCode)
        await gate.open()
        await task.value
        await fulfillment(of: [late], timeout: 1)
        let events = await store.events()
        XCTAssertEqual(events.filter { $0 == "send" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "complete" }.count, 1)
        let after = await store.completedErrorCode(handle: snapshot.handle)
        XCTAssertEqual(after, before)
    }

    func testManualSwitchWorkerCommandsUseExactNativeEnvelopes() throws {
        func decode(_ values: [String: Any]) throws -> InternalSafariRequest {
            try JSONDecoder().decode(
                InternalSafariRequest.self,
                from: JSONSerialization.data(withJSONObject: values)
            )
        }
        let listing: [String: Any] = [
            "id": 400,
            "subject": "getManualSwitchRequests",
            "workflowVersion": ExtensionBridge.workflowVersion,
        ]
        guard case .worker(.getManualSwitchRequests(let cursor)) =
            try decode(listing).command else {
            return XCTFail("Expected a worker-only discovery command")
        }
        XCTAssertNil(cursor)
        var paginated = listing
        paginated["cursor"] = "opaque-cursor"
        guard case .worker(.getManualSwitchRequests(let next)) =
            try decode(paginated).command else {
            return XCTFail("Expected a paginated discovery command")
        }
        XCTAssertEqual(next, "opaque-cursor")
        for invalid in [NSNull(), 1, true] as [Any] {
            var malformed = listing
            malformed["cursor"] = invalid
            XCTAssertThrowsError(try decode(malformed))
        }
        let token = UUID().uuidString.lowercased()
        let response: [String: Any] = [
            "id": 401,
            "subject": "getManualSwitchResponse",
            "workflowVersion": ExtensionBridge.workflowVersion,
            "configurationKey": "https://wallet.example",
            "requestToken": token,
            "revisions": ["ethereum": 1, "solana": 2],
            "executionDeadline": 2_000_000_900_000,
        ]
        guard case .worker(.getManualSwitchResponse(let identity)) =
            try decode(response).command else {
            return XCTFail("Expected a worker-only response command")
        }
        XCTAssertEqual(identity.token.rawValue, token)
        XCTAssertEqual(identity.configurationKey, "https://wallet.example")
        XCTAssertEqual(identity.revisions.ethereum, 1)
        XCTAssertEqual(identity.revisions.solana, 2)
        XCTAssertEqual(identity.executionDeadline.timeIntervalSince1970, 2_000_000_900)
        for extra in ["profileIdentifier", "privateBrowsing", "host", "payload"] {
            for original in [listing, response] {
                var malformed = original
                malformed[extra] = "untrusted"
                XCTAssertThrowsError(try decode(malformed))
            }
        }
        for field in ["configurationKey", "requestToken", "revisions", "executionDeadline"] {
            var malformed = response
            malformed.removeValue(forKey: field)
            XCTAssertThrowsError(try decode(malformed))
        }
    }

    func testManualSwitchRecoveryHandlerKeepsItsQuietModeThroughFinalization() throws {
        let handler = try source(named: "Safari Shared/SafariWebExtensionHandler.swift")
        XCTAssertTrue(handler.contains("_ command: InternalSafariRequest.WorkerCommand"))
        XCTAssertTrue(handler.contains("Self.bridge.loadManualSwitch("))
        XCTAssertTrue(handler.contains("Self.bridge.listManualSwitchRequests("))
        XCTAssertTrue(handler.contains("\"requests\": page.requests.map(\\.json)"))
        XCTAssertTrue(handler.contains("mode: .manualRecovery"))
        XCTAssertTrue(handler.contains("initialContext: executionContext,\n                            mode: mode"))
        XCTAssertTrue(handler.contains("NativeAgentLauncher.hasCompatibleApprovalDelivery("))
        XCTAssertTrue(handler.contains("respond(with: [\"id\": id, \"pending\": true]"))
        let worker = try source(named: "Safari Shared/Resources/service_worker.js")
        XCTAssertFalse(worker.contains("case \"getManualSwitchRequests\":"))
        XCTAssertFalse(worker.contains("case \"getManualSwitchResponse\":"))
    }

    func testExtensionHandlerAwaitsPopupDispatchBeforeResponding() throws {
        let source = try source(named: "Safari Shared/SafariWebExtensionHandler.swift")
        XCTAssertTrue(source.contains("response = await PopupRequestSessions.dispatch("))
        XCTAssertTrue(source.contains("response = await PopupRequestSessions.dispatchPrivateBrowsing("))
    }

    func testExtensionHandlerPreservesUnstagedAdmissionAfterLaunchFailure() throws {
        let source = try source(named: "Safari Shared/SafariWebExtensionHandler.swift")
        XCTAssertTrue(source.contains("reconcileAfterNativeLaunchFailure"))
        XCTAssertTrue(source.contains(
            "NativeAgentLauncher.currentApprovalDeliveryStatus"
        ))
        XCTAssertTrue(source.contains("nativeLaunchWasDelivered"))
        XCTAssertFalse(source.contains("failClosedAfterNativeLaunchFailure"))
        XCTAssertFalse(source.contains("switch admissionKind"))
    }

    #if os(macOS)
    func testQuietNativeDeliveryWaitsForApprovalWithoutProcessActions() async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        )
        var snapshot = try popupSnapshot(id: 403, nativeDeliveryReceipt: receipt)
        var runtimeChecks = 0
        var quitCount = 0
        var clearCount = 0
        var waitCount = 0
        var compatible = true
        let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { _ in .found(snapshot) },
            receiptRuntimeStatus: { _ in
                runtimeChecks += 1
                if compatible {
                    return .compatible(.running(
                        url: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
                        processIdentifier: 1,
                        runtimeInstanceIdentifier: receipt.runtimeInstanceIdentifier
                    ))
                }
                return .incompatible(.init(
                    requestQuit: { _ in quitCount += 1; return true },
                    isRunning: { true }
                ))
            },
            clearReceipt: { _, _ in clearCount += 1; return .persisted },
            wait: { _ in waitCount += 1 }
        )
        let pending = await NativeAgentLauncher.hasCompatibleApprovalDelivery(
            handle: snapshot.handle, nativeDeliveryNonce: nonce, dependencies: dependencies
        )
        XCTAssertFalse(pending)
        XCTAssertEqual(runtimeChecks, 0)
        snapshot = try popupSnapshot(
            id: 403, nativeDecisionStaged: true, nativeDeliveryReceipt: receipt
        )
        let approved = await NativeAgentLauncher.hasCompatibleApprovalDelivery(
            handle: snapshot.handle, nativeDeliveryNonce: nonce, dependencies: dependencies
        )
        XCTAssertTrue(approved)
        compatible = false
        let incompatible = await NativeAgentLauncher.hasCompatibleApprovalDelivery(
            handle: snapshot.handle, nativeDeliveryNonce: nonce, dependencies: dependencies
        )
        XCTAssertFalse(incompatible)
        XCTAssertEqual(quitCount, 0)
        XCTAssertEqual(clearCount, 0)
        XCTAssertEqual(waitCount, 0)
    }

    func testQuietNativeDeliveryRejectsAbsentOrMismatchedReceiptOwner() async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        )
        let snapshot = try popupSnapshot(
            id: 402, phase: .approving,
            nativeDecisionStaged: true, nativeDeliveryReceipt: receipt
        )
        for runtimeStatus: NativeAgentLauncher.ReceiptRuntimeStatus in [
            .absent, .indeterminate,
            .compatible(.running(
                url: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
                processIdentifier: 1,
                runtimeInstanceIdentifier: UUID()
            )),
        ] {
            let allowed = await NativeAgentLauncher.hasCompatibleApprovalDelivery(
                handle: snapshot.handle,
                nativeDeliveryNonce: nonce,
                dependencies: .init(
                    load: { _ in .found(snapshot) },
                    receiptRuntimeStatus: { _ in runtimeStatus },
                    clearReceipt: { _, _ in
                        XCTFail("Quiet recovery must retain the receipt")
                        return .persisted
                    },
                    wait: { _ in XCTFail("Quiet observation must not wait for a helper") }
                )
            )
            XCTAssertFalse(allowed)
        }
    }

    func testNativeLaunchReconciliationRequiresLiveExactReceipt() async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let snapshot = try popupSnapshot(
            id: 404,
            nativeDeliveryReceipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: UUID(),
                owner: popupNativeDeliveryOwner
            )
        )
        let liveDependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
            load: { _ in .found(snapshot) },
            runtimeStatus: { instanceIdentifier in
                .compatible(.running(
                    url: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
                    processIdentifier: 1,
                    runtimeInstanceIdentifier: instanceIdentifier
                ))
            },
            clearReceipt: { _, _ in .ownershipLost },
            wait: { _ in }
        )
        let live = await NativeAgentLauncher.currentApprovalDeliveryStatus(
            handle: snapshot.handle,
            nativeDeliveryNonce: nonce,
            dependencies: liveDependencies
        )
        XCTAssertEqual(live, .delivered)

        let indeterminateDependencies =
            NativeAgentLauncher.ApprovalDeliveryDependencies(
                load: { _ in .found(snapshot) },
                runtimeStatus: { _ in .indeterminate },
                clearReceipt: { _, _ in .persisted },
                wait: { _ in }
            )
        let indeterminate = await NativeAgentLauncher
            .currentApprovalDeliveryStatus(
                handle: snapshot.handle,
                nativeDeliveryNonce: nonce,
                dependencies: indeterminateDependencies
        )
        XCTAssertEqual(indeterminate, .unavailable)
    }

    func testStagedNativeDeliveryRequiresCompatibleLiveReceipt() async throws {
        for phase in [ExtensionBridge.Phase.queued, .approving] {
            let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
            let receipt = ExtensionBridge.NativeDeliveryReceipt(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: UUID(),
                owner: popupNativeDeliveryOwner
            )
            let snapshot = try popupSnapshot(
                id: phase == .queued ? 406 : 407,
                phase: phase,
                nativeDecisionStaged: true,
                nativeDeliveryReceipt: receipt
            )
            let dependencies = NativeAgentLauncher.ApprovalDeliveryDependencies(
                load: { _ in .found(snapshot) },
                receiptRuntimeStatus: { checkedReceipt in
                    XCTAssertEqual(checkedReceipt, receipt)
                    return .compatible(.running(
                        url: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
                        processIdentifier: 1,
                        runtimeInstanceIdentifier: receipt.runtimeInstanceIdentifier
                    ))
                },
                clearReceipt: { _, _ in
                    XCTFail("A live compatible receipt must be retained")
                    return .ownershipLost
                },
                wait: { _ in }
            )

            let status = await NativeAgentLauncher.approvalDeliveryStatus(
                handle: snapshot.handle,
                nativeDeliveryNonce: nonce,
                isPending: { true },
                dependencies: dependencies
            )

            XCTAssertEqual(status, .delivered)
        }
    }

    func testStagedNativeDeliveryWithoutReceiptNeedsRedelivery() async throws {
        let snapshot = try popupSnapshot(
            id: 408,
            nativeDecisionStaged: true
        )
        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: snapshot.handle,
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            isPending: { true },
            dependencies: .init(
                load: { _ in .found(snapshot) },
                receiptRuntimeStatus: { _ in
                    XCTFail("A missing receipt has no runtime to inspect")
                    return .indeterminate
                },
                clearReceipt: { _, _ in
                    XCTFail("A missing receipt does not need clearing")
                    return .ownershipLost
                },
                wait: { _ in }
            )
        )

        XCTAssertEqual(status, .needsDelivery)
    }

    func testStagedNativeDeliveryClearsAbsentOwnerForRedelivery() async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        )
        let snapshot = try popupSnapshot(
            id: 409,
            nativeDecisionStaged: true,
            nativeDeliveryReceipt: receipt
        )
        var clearedReceipt: ExtensionBridge.NativeDeliveryReceipt?
        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: snapshot.handle,
            nativeDeliveryNonce: nonce,
            isPending: { true },
            dependencies: .init(
                load: { _ in .found(snapshot) },
                receiptRuntimeStatus: { _ in .absent },
                clearReceipt: { _, receipt in
                    clearedReceipt = receipt
                    return .persisted
                },
                wait: { _ in }
            )
        )

        XCTAssertEqual(status, .needsDelivery)
        XCTAssertEqual(clearedReceipt, receipt)
    }

    func testApprovingNativeDeliveryQuitsIncompatibleOwnerBeforeRedelivery()
        async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        )
        let snapshot = try popupSnapshot(
            id: 410,
            phase: .approving,
            nativeDecisionStaged: true,
            nativeDeliveryReceipt: receipt
        )
        var events = [String]()
        let owner = NativeAgentLauncher.ExactReceiptOwner(
            requestQuit: { _ in
                events.append("quit")
                return true
            },
            isRunning: {
                events.append("running")
                return false
            }
        )
        let status = await NativeAgentLauncher.approvalDeliveryStatus(
            handle: snapshot.handle,
            nativeDeliveryNonce: nonce,
            isPending: { true },
            dependencies: .init(
                load: { _ in .found(snapshot) },
                receiptRuntimeStatus: { _ in .incompatible(owner) },
                clearReceipt: { _, _ in
                    events.append("clear")
                    return .persisted
                },
                wait: { _ in }
            )
        )

        XCTAssertEqual(status, .needsDelivery)
        XCTAssertEqual(events, ["quit", "running", "clear"])
    }
    #endif

    func testResponsePollingHealsMissingNativeApprovalDelivery() throws {
        let source = try source(
            named: "Safari Shared/SafariWebExtensionHandler.swift"
        )
        XCTAssertTrue(source.contains(
            "ensureNativeApprovalDeliveryIfNeeded"
        ))
        XCTAssertTrue(source.contains(
            "nativeDeliveryNonce: snapshot.nativeDeliveryNonce"
        ))
        XCTAssertTrue(source.contains("recordNativeExecutionContext"))
        XCTAssertTrue(source.contains("acquireNativeExecutionFence"))
        XCTAssertTrue(source.contains("waitForNativeApprovalFinalization"))
        XCTAssertTrue(source.contains("snapshot.phase != .responded"))
        XCTAssertFalse(source.contains(
            "NativeApprovalFinalizer.shared.finalize("
        ))
    }

    func testCancelledTransactionSpeedLeavesFeeAndSelectionUnchanged() throws {
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 300
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 300
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        let network = EthereumNetwork(
            chainId: EthereumNetwork.ethMainnetChainId,
            name: "Ethereum",
            symbol: "ETH",
            rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
            isTestnet: false,
            mightShowPrice: true,
            explorer: nil
        )
        let action = SendTransactionAction(
            transaction: transaction,
            resolvedNetwork: ResolvedEthereumNetwork(
                network: network,
                source: .custom
            ),
            walletId: "wallet",
            account: popupTestAccount(),
            resolve: { _ -> DappExecutionResult in fatalError() }
        )
        var preparationCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { _, _, _, _, _, _ in
                preparationCount += 1
                return EthereumRequestCancellation()
            },
            preflight: { _, _, _ in EthereumRequestCancellation() }
        )
        let session = PopupTransactionSession(
            action: action,
            operations: operations
        )
        session.start()
        let fee = session.snapshot.transaction.preparedFee
        let position = session.gasSliderPosition(for: session.snapshot.transaction)
        let payloadData = try JSONSerialization.data(withJSONObject: [
            "interaction": "cancelled",
            "value": 200,
        ])
        let payload = try JSONDecoder().decode(
            InternalSafariRequest.TransactionSpeedPayload.self,
            from: payloadData
        )

        session.setSpeed(payload)

        XCTAssertEqual(session.snapshot.transaction.preparedFee, fee)
        XCTAssertEqual(
            session.gasSliderPosition(for: session.snapshot.transaction),
            position
        )
        XCTAssertEqual(preparationCount, 1)
    }

    func testPriorityFeeEditPreservesUntouchedFeeCapProvenance() {
        for source in [TransactionFeeSource.automatic, .dapp] {
            let session = makeFeeEditingSession(provenance: .init(
                maxPriorityFeePerGas: source,
                maxFeePerGas: source
            ))

            XCTAssertTrue(session.applyEdits(
                .custom(.init(
                    nonce: "0",
                    gasPriceGwei: nil,
                    maxPriorityFeePerGasGwei: "0.00000015",
                    maxFeePerGasGwei: "0.0000003"
                )),
                chain: popupTransactionNetwork()
            ))

            XCTAssertEqual(session.snapshot.transaction.preparedFee, .eip1559(
                maxPriorityFeePerGas: 150,
                maxFeePerGas: 300
            ))
            XCTAssertEqual(session.snapshot.transaction.feeProvenance, .init(
                maxPriorityFeePerGas: .manual,
                maxFeePerGas: source
            ))
        }
    }

    func testFeeCapEditPreservesUntouchedPriorityFeeProvenance() {
        for source in [TransactionFeeSource.automatic, .dapp] {
            let session = makeFeeEditingSession(provenance: .init(
                maxPriorityFeePerGas: source,
                maxFeePerGas: source
            ))

            XCTAssertTrue(session.applyEdits(
                .custom(.init(
                    nonce: "0",
                    gasPriceGwei: nil,
                    maxPriorityFeePerGasGwei: "0.0000001",
                    maxFeePerGasGwei: "0.0000004"
                )),
                chain: popupTransactionNetwork()
            ))

            XCTAssertEqual(session.snapshot.transaction.preparedFee, .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 400
            ))
            XCTAssertEqual(session.snapshot.transaction.feeProvenance, .init(
                maxPriorityFeePerGas: source,
                maxFeePerGas: .manual
            ))
        }
    }

    func testCustomFeeEditReplacesSliderProvenanceForBothFields() {
        let provenances = [
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .slider,
                maxFeePerGas: .slider
            ),
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .slider,
                maxFeePerGas: .automatic
            ),
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .automatic,
                maxFeePerGas: .slider
            ),
        ]
        for provenance in provenances {
            for changesPriority in [true, false] {
                let session = makeFeeEditingSession(provenance: provenance)

                XCTAssertTrue(session.applyEdits(
                    .custom(.init(
                        nonce: "0",
                        gasPriceGwei: nil,
                        maxPriorityFeePerGasGwei: changesPriority
                            ? "0.00000015" : "0.0000001",
                        maxFeePerGasGwei: changesPriority
                            ? "0.0000003" : "0.0000004"
                    )),
                    chain: popupTransactionNetwork()
                ))

                XCTAssertEqual(session.snapshot.transaction.feeProvenance, .init(
                    maxPriorityFeePerGas: .manual,
                    maxFeePerGas: .manual
                ))
            }
        }
    }

    func testNonceOnlyEditPreservesFeeProvenance() {
        for source in [TransactionFeeSource.automatic, .dapp, .slider] {
            let provenance = TransactionFeeProvenance(
                maxPriorityFeePerGas: source,
                maxFeePerGas: source
            )
            let session = makeFeeEditingSession(provenance: provenance)

            XCTAssertTrue(session.applyEdits(
                .custom(.init(
                    nonce: "1",
                    gasPriceGwei: nil,
                    maxPriorityFeePerGasGwei: "0.0000001",
                    maxFeePerGasGwei: "0.0000003"
                )),
                chain: popupTransactionNetwork()
            ))

            XCTAssertEqual(session.snapshot.transaction.decimalNonceString, "1")
            XCTAssertEqual(session.snapshot.transaction.feeProvenance, provenance)
        }
    }

    private func makeFeeEditingSession(
        provenance: TransactionFeeProvenance
    ) -> PopupTransactionSession {
        let transaction = Transaction(
            from: popupTestAccount().address,
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 300
            ),
            feeProvenance: provenance,
            currentBaseFeePerGas: 100
        )
        let session = PopupTransactionSession(
            action: SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: popupTransactionNetwork(),
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ -> DappExecutionResult in fatalError() }
            ),
            operations: TransactionApprovalOperations(
                prepare: { transaction, _, _, _, _, completion in
                    completion(.success(transaction))
                    return EthereumRequestCancellation()
                },
                preflight: { _, _, _ in EthereumRequestCancellation() }
            )
        )
        session.start()
        return session
    }

    func testQueueSortingRemainsFIFO() throws {
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        XCTAssertTrue(source.contains("$0.sequence < $1.sequence"))
    }

    private func makeSession() throws -> PopupRequestSession {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 42,
            "name": "switchAccount",
            "provider": "unknown",
            "host": "wallet.example",
            "configurationKey": "wallet.example",
            "enqueueAttempt": String(repeating: "a", count: 32),
            "admissionDeadline": popupRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["latestConfigurations": []],
        ])
        let request = try XCTUnwrap(SafariRequest(data: data))
        let handle = ExtensionBridge.Handle(
            id: request.id,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
        return PopupRequestSession(
            handle: handle,
            request: request,
            purpose: .approval(.switchAccount(SelectAccountAction(
                coinType: nil,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: nil,
                resolve: { _, _ in request.response(error: .userRejected) }
            )))
        )
    }

    private func source(named relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

@MainActor
extension PopupRequestSessionsTests {

    func testPendingResponseIsFIFO() async throws {
        let store = CompactPopupStore()
        let receivedAt = Date(timeIntervalSince1970: 1)
        let first = try popupSnapshot(
            id: 1,
            createdAt: receivedAt,
            provider: .ethereum
        )
        let second = try popupSnapshot(id: 2, createdAt: receivedAt)
        await store.insert(second)
        await store.insert(first)
        let controller = popupController(store: store)
        let request = try popupCommand(subject: "getPendingRequests", id: 99)

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(response["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.compactMap { $0["id"] as? Int }, [1, 2])
        XCTAssertEqual(
            requests.compactMap { $0["configurationKey"] as? String },
            ["wallet.example", "wallet.example"]
        )
        XCTAssertEqual(
            requests.compactMap { $0["provider"] as? String },
            ["ethereum", "unknown"]
        )
        XCTAssertEqual(
            requests.compactMap {
                ExtensionBridge.ProviderRevisions(rawValue: $0["revisions"])
            },
            [first.revisions, second.revisions]
        )
    }

    func testPendingResponseCarriesCompletedIdentitiesBeforeQueuedRequests() async throws {
        let store = CompactPopupStore()
        let completed = try popupSnapshot(
            id: 10,
            createdAt: Date(timeIntervalSince1970: 1),
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 2, solana: 3),
            phase: .responded
        )
        let pending = try popupSnapshot(
            id: 11,
            createdAt: Date(timeIntervalSince1970: 2),
            provider: .solana
        )
        await store.insert(pending)
        await store.insert(completed)
        let controller = popupController(store: store)
        let request = try popupCommand(subject: "getPendingRequests", id: 99)

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(response["requests"] as? [[String: Any]])
        let completedResponses = try XCTUnwrap(
            response["completedResponses"] as? [[String: Any]]
        )
        XCTAssertEqual(requests.compactMap { $0["id"] as? Int }, [pending.handle.id])
        XCTAssertEqual(completedResponses.count, 1)
        XCTAssertEqual(completedResponses[0]["id"] as? Int, completed.handle.id)
        XCTAssertEqual(completedResponses[0]["host"] as? String, completed.host)
        XCTAssertEqual(
            completedResponses[0]["configurationKey"] as? String,
            completed.configurationKey
        )
        XCTAssertEqual(
            completedResponses[0]["requestToken"] as? String,
            completed.handle.requestToken
        )
        XCTAssertEqual(
            ExtensionBridge.ProviderRevisions(
                rawValue: completedResponses[0]["revisions"]
            ),
            completed.revisions
        )
    }

    func testUnavailableSessionReturnsCompactRefreshOnlyError() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 20)
        await store.insert(snapshot)
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor(),
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: { false }
            ),
            loadsTransactionContext: false
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: 20,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(response.keys), ["id", "state", "host", "error"])
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil(response["reviewToken"])
        XCTAssertNil(response["canReject"])
    }

    func testNonemptySwitchMaterializesImmediateResponseAfterWalletReload() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSwitchSnapshot(
            id: 24,
            address: "0x0000000000000000000000000000000000000001"
        )
        await store.insert(snapshot)
        var walletStarts = 0
        var preparations = 0
        let processor = CompactPopupProcessor { request in
            preparations += 1
            return .response(ResponseToExtension(
                for: request,
                payload: .body(.ethereum(.init(
                    results: ["0x0000000000000000000000000000000000000001"],
                    chainId: "0x1"
                )))
            ))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: {
                    walletStarts += 1
                    return true
                }
            ),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle
        )

        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(walletStarts, 1)
        XCTAssertEqual(preparations, 1)
        let loadCount = await store.loadCount()
        XCTAssertEqual(loadCount, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["complete"])
    }

    func testUnknownNonemptySwitchPersistsWithoutStartingWallets() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSwitchSnapshot(
            id: 26,
            address: "0x0000000000000000000000000000000000000001",
            requestedChainId: "0x7fffffffffffffff"
        )
        await store.insert(snapshot)
        var walletStarts = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: ProductionPopupRequestProcessor(),
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: {
                    walletStarts += 1
                    return false
                }
            ),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle
        )

        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(walletStarts, 0)
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        XCTAssertEqual(errorCode, 4902)
    }

    func testReceiptOwnedReplaySkipsWalletMaterialization() async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        )
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 30,
            provider: .ethereum,
            nativeDeliveryReceipt: receipt
        )
        await store.insert(snapshot)
        var walletStarts = 0
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .response(request.response(error: .internalError))
            },
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: {
                    walletStarts += 1
                    return false
                }
            ),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle,
            materializesWalletDependentRequests: true
        )

        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(walletStarts, 0)
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testWalletDependentAdmissionDefersWhenLocalMaterializationIsDisabled()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 31, provider: .ethereum)
        await store.insert(snapshot)
        var walletStarts = 0
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .response(request.response(error: .internalError))
            },
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: {
                    walletStarts += 1
                    return true
                }
            ),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle,
            materializesWalletDependentRequests: false
        )

        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(walletStarts, 0)
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testWalletDependentImmediateResponseUsesLocalMaterializationWhenEnabled()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 27, provider: .ethereum)
        await store.insert(snapshot)
        var walletStarts = 0
        var preparations = 0
        let processor = CompactPopupProcessor { request in
            preparations += 1
            return .response(request.response(error: .internalError))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: {
                    walletStarts += 1
                    return true
                }
            ),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle,
            materializesWalletDependentRequests: true
        )

        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(walletStarts, 1)
        XCTAssertEqual(preparations, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["complete"])
    }

    func testCompletionOwnershipLossToReceiptRequiresApprovalDelivery()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 32, provider: .ethereum)
        await store.insert(snapshot)
        await store.forceNextCompletionOwnershipLoss(receipt: .init(
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        ))
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .response(request.response(error: .internalError))
            },
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle,
            materializesWalletDependentRequests: true
        )

        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(preparations, 1)
    }

    func testStagedDecisionReplaySkipsRequestRematerialization() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 29,
            nativeDecisionStaged: true
        )
        await store.insert(snapshot)
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .response(request.response(error: .internalError))
            },
            walletEnvironment: SourcePopupWalletEnvironment(
                startWalletsManager: {
                    XCTFail("A staged decision must not restart admission")
                    return false
                }
            ),
            loadsTransactionContext: false
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle
        )

        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testImmediateResponsePersistenceShowsWorkingUntilReconciled() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 28)
        await store.insert(snapshot)
        await store.suspendNextCompletion()
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                .response(request.response(error: .userRejected))
            },
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(state.keys), ["id", "state", "host"])
        XCTAssertEqual(state["id"] as? Int, snapshot.handle.id)
        XCTAssertEqual(state["state"] as? String, "working")
        XCTAssertEqual(state["host"] as? String, snapshot.host)

        try await waitForEvent("completeStarted", store: store)
        await store.resumeCompletion()
        try await waitForEvent("complete", store: store)
        let pendingRequest = try popupCommand(subject: "getPendingRequests", id: 99)
        let pending = await controller.dispatch(
            try popupCommandValue(pendingRequest),
            request: pendingRequest,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(pending["requests"] as? [[String: Any]])
        let completed = try XCTUnwrap(
            pending["completedResponses"] as? [[String: Any]]
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0]["id"] as? Int, snapshot.handle.id)
        XCTAssertEqual(
            completed[0]["requestToken"] as? String,
            snapshot.handle.requestToken
        )
    }

    func testColdControllerShowsWorkingForApprovingSnapshot() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 22, phase: .approving)
        await store.insert(snapshot)
        var preparationCount = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparationCount += 1
                return .approval(.addEthereumChain(AddEthereumChainAction(
                    chainToAdd: popupTestNetwork(),
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            },
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "working")
        XCTAssertEqual(response["host"] as? String, snapshot.host)
        XCTAssertNil(response["reviewToken"])
        XCTAssertEqual(preparationCount, 0)
    }

    func testReceiptOwnedApprovalStateInvalidatesCachedReview() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 31)
        await store.insert(snapshot)
        var preparationCount = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparationCount += 1
                return .approval(.addEthereumChain(AddEthereumChainAction(
                    chainToAdd: popupTestNetwork(),
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            },
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let initial = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let initialToken = try XCTUnwrap(initial["reviewToken"] as? String)
        XCTAssertEqual(preparationCount, 1)
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID(),
            owner: popupNativeDeliveryOwner
        )
        await store.setNativeDeliveryReceipt(receipt, handle: snapshot.handle)

        let owned = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(owned.keys), ["id", "state", "host"])
        XCTAssertEqual(owned["state"] as? String, "working")
        XCTAssertEqual(owned["host"] as? String, snapshot.host)
        XCTAssertNil(owned["reviewToken"])
        XCTAssertEqual(preparationCount, 1)

        await store.setNativeDeliveryReceipt(nil, handle: snapshot.handle)
        let restored = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let restoredToken = try XCTUnwrap(restored["reviewToken"] as? String)
        XCTAssertNotEqual(restoredToken, initialToken)
        XCTAssertEqual(preparationCount, 2)
    }

    func testStagedNativeApprovalRemainsPendingAndShowsWorking() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 32,
            nativeDecisionStaged: true
        )
        await store.insert(snapshot)
        var preparationCount = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparationCount += 1
                return .approval(.addEthereumChain(AddEthereumChainAction(
                    chainToAdd: popupTestNetwork(),
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            },
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        let pendingRequest = try popupCommand(
            subject: "getPendingRequests",
            id: 99
        )
        let pending = await controller.dispatch(
            try popupCommandValue(pendingRequest),
            request: pendingRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(state.keys), ["id", "state", "host"])
        XCTAssertEqual(state["state"] as? String, "working")
        XCTAssertEqual(state["host"] as? String, snapshot.host)
        XCTAssertNil(state["reviewToken"])
        XCTAssertEqual(preparationCount, 0)
        let requests = try XCTUnwrap(pending["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0]["id"] as? Int, snapshot.handle.id)
    }

    func testCachedControllerShowsWorkingAfterForeignClaim() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 23)
        await store.insert(snapshot)
        let controller = popupController(store: store)
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let initial = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        XCTAssertNotNil(initial["reviewToken"])
        guard case .claimed = await store.claim(handle: snapshot.handle) else {
            return XCTFail("Expected foreign claim")
        }

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "working")
        XCTAssertEqual(response["host"] as? String, snapshot.host)
        XCTAssertNil(response["reviewToken"])
    }

    func testSelectionRefreshFailureReturnsCompactError() async throws {
        var refreshEvents = [String]()
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 21)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.switchAccount(SelectAccountAction(
                coinType: nil,
                selectedAccounts: [],
                initiallyConnectedProviders: [.ethereum],
                network: nil,
                resolve: { _, _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                refresh: {
                    refreshEvents.append("refresh")
                    return false
                }
            ),
            loadsTransactionContext: false,
            invalidateNetworkCache: { refreshEvents.append("invalidate") }
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: 21,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        _ = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(response.keys), ["id", "state", "host", "error"])
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil(response["reviewToken"])
        XCTAssertEqual(refreshEvents, ["refresh", "invalidate"])
    }

    func testAccountSelectionRejectsDuplicateSameCoinAndWrongCoinAccountsBeforeClaim() async throws {
        let firstAccount = WalletAccount(
            address: "solana-public-key-1",
            coin: .solana,
            derivation: .solanaSolana,
            derivationPath: "m/44'/501'/0'/0'",
            publicKey: "",
            extendedPublicKey: ""
        )
        let secondAccount = WalletAccount(
            address: "solana-public-key-2",
            coin: .solana,
            derivation: .solanaSolana,
            derivationPath: "m/44'/501'/1'/0'",
            publicKey: "",
            extendedPublicKey: ""
        )
        let wrongCoinAccount = popupTestAccount()
        let accountsByAddress = [
            firstAccount.address: firstAccount,
            secondAccount.address: secondAccount,
            wrongCoinAccount.address: wrongCoinAccount,
        ]

        for (index, selectedAccounts) in [
            [firstAccount, firstAccount],
            [firstAccount, secondAccount],
            [wrongCoinAccount],
        ].enumerated() {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: 40 + index, provider: .solana)
            await store.insert(snapshot)
            var resolveCount = 0
            let processor = CompactPopupProcessor { request in
                .approval(.selectAccount(SelectAccountAction(
                    coinType: .solana,
                    selectedAccounts: [],
                    initiallyConnectedProviders: [],
                    network: nil,
                    resolve: { _, _ in
                        resolveCount += 1
                        return request.response(error: .userRejected)
                    }
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: processor,
                walletEnvironment: TestPopupWalletEnvironment(
                    refresh: { true },
                    resolve: { item in
                        guard let account = accountsByAddress[item.address] else {
                            return nil
                        }
                        return SpecificWalletAccount(
                            walletId: item.walletId,
                            account: account
                        )
                    }
                ),
                loadsTransactionContext: false
            )
            let token = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )
            let approve = try popupCommand(
                subject: "approveRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                reviewToken: token,
                payload: [
                    "selectedAccounts": selectedAccounts.map { account in
                        [
                            "walletId": "wallet",
                            "address": account.address,
                            "coin": account.coin.correspondingInpageProvider.rawValue,
                            "derivationPath": account.derivationPath,
                        ]
                    },
                    "revisions": snapshot.revisions.json,
                ]
            )

            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            let events = await store.events()

            XCTAssertEqual(response["status"] as? String, "ok")
            XCTAssertEqual(resolveCount, 0)
            XCTAssertTrue(events.isEmpty)
            let stateRequest = try popupCommand(
                subject: "getApprovalState",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                payload: ["mode": "poll"]
            )
            let state = await controller.dispatch(
                try popupCommandValue(stateRequest),
                request: stateRequest,
                profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "review")
            XCTAssertEqual(state["error"] as? String, Strings.somethingWentWrong)
            XCTAssertEqual(state["reviewToken"] as? String, token)
        }
    }

    func testStaleReviewTokenRejectsApproveAndMutation() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 3)
        await store.insert(snapshot)
        let controller = popupController(store: store)
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: 3,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertNotNil(state["reviewToken"] as? String)

        for subject in ["approveRequest", "applyTransactionEdits"] {
            let payload: [String: Any] = subject == "approveRequest"
                ? [:]
                : ["mode": "suggested"]
            let request = try popupCommand(
                subject: subject,
                id: 3,
                requestToken: snapshot.handle.requestToken,
                reviewToken: UUID().uuidString.lowercased(),
                payload: payload
            )
            let response = await controller.dispatch(
                try popupCommandValue(request),
                request: request,
                profileIdentifier: nil
            )
            XCTAssertEqual(response["status"] as? String, "ignored")
        }
        let staleEvents = await store.events()
        XCTAssertTrue(staleEvents.isEmpty)
    }

    func testAddChainApprovalSkipsRevisionsAndRejectUsesSingleActionPath() async throws {
        let store = CompactPopupStore()
        let approved = try popupSnapshot(id: 4)
        await store.insert(approved)
        let controller = popupController(store: store)
        let reviewToken = try await materializeToken(
            controller: controller,
            snapshot: approved
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 4,
            requestToken: approved.handle.requestToken,
            reviewToken: reviewToken,
            payload: [
                "revisions": popupRevisions(ethereum: 99, solana: 99).json,
            ]
        )
        let approvalResponse = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let approvalEvents = await store.events()
        XCTAssertEqual(approvalResponse["status"] as? String, "ok")
        XCTAssertEqual(approvalEvents, ["claim", "begin", "complete"])
        let approvalWasCommitted = await store.completedApprovalWasCommitted(
            handle: approved.handle
        )
        XCTAssertTrue(approvalWasCommitted)

        let rejected = try popupSnapshot(id: 5)
        await store.insert(rejected)
        _ = try await materializeToken(
            controller: controller,
            snapshot: rejected
        )
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: 5,
            requestToken: rejected.handle.requestToken
        )
        _ = await controller.dispatch(
            try popupCommandValue(reject),
            request: reject,
            profileIdentifier: nil
        )
        let rejectionEvents = await store.events()
        XCTAssertEqual(rejectionEvents.last, "reject")

        XCTAssertThrowsError(try popupCommand(
            subject: "rejectRequest",
            id: 6,
            requestToken: rejected.handle.requestToken,
            reviewToken: UUID().uuidString.lowercased()
        ))
    }

    func testColdControllerRejectsQueuedHandleWithoutMaterializingSession() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 25)
        await store.insert(snapshot)
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .approval(.addEthereumChain(AddEthereumChainAction(
                    chainToAdd: popupTestNetwork(),
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            },
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )

        let response = await controller.dispatch(
            try popupCommandValue(reject),
            request: reject,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["reject"])
    }

    func testFailedRejectPreservesCachedReviewSession() async throws {
        for (result, expectedStatus) in [
            (ExtensionBridge.StoreMutationResult.ownershipLost, "ignored"),
            (.retryablePersistenceFailure, "unavailable"),
        ] {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: 27)
            await store.insert(snapshot)
            var preparations = 0
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork(),
                        resolve: { _ in request.response(error: .userRejected) }
                    )))
                },
                walletEnvironment: TestPopupWalletEnvironment(),
                loadsTransactionContext: false
            )
            let originalToken = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )
            await store.forceNextRejectResult(result)
            let reject = try popupCommand(
                subject: "rejectRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )

            let response = await controller.dispatch(
                try popupCommandValue(reject),
                request: reject,
                profileIdentifier: nil
            )
            let retainedToken = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )

            XCTAssertEqual(response["status"] as? String, expectedStatus)
            XCTAssertEqual(retainedToken, originalToken)
            XCTAssertEqual(preparations, 1)
        }
    }

    func testAuthenticationFailureReleasesClaimAndReturnsToReview() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 6)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(false) }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 6,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let releaseEvents = await store.events()
        XCTAssertEqual(releaseEvents, ["claim", "release"])
        let refreshed = try popupCommand(
            subject: "getApprovalState",
            id: 6,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(refreshed),
            request: refreshed,
            profileIdentifier: nil
        )
        XCTAssertEqual(state["state"] as? String, "review")
    }

    func testFailedClaimReleaseDoesNotRestoreActionableReview() async throws {
        for result in [
            ExtensionBridge.StoreMutationResult.retryablePersistenceFailure,
            .ownershipLost,
        ] {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: 476)
            await store.insert(snapshot)
            await store.forceNextReleaseResult(result)
            var authenticatedSession: PopupRequestSession?
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: CompactPopupProcessor { request in
                    .approval(.approveMessage(SignMessageAction(
                        subject: .signMessage,
                        walletId: "wallet",
                        account: popupTestAccount(),
                        meta: "message",
                        resolve: { _ in
                            XCTFail("A failed release must not sign")
                            return request.response(error: .internalError)
                        }
                    )))
                },
                walletEnvironment: TestPopupWalletEnvironment(
                    authenticate: { session, _, completion in
                        authenticatedSession = session
                        completion(false)
                    }
                ),
                loadsTransactionContext: false
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            let approve = try popupCommand(
                subject: "approveRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                reviewToken: token,
                payload: ["revisions": snapshot.revisions.json]
            )
            _ = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            let session = try XCTUnwrap(authenticatedSession)
            if result == .retryablePersistenceFailure {
                XCTAssertEqual(session.state, .error)
                XCTAssertEqual(session.errorText, Strings.failedToLoad)
                XCTAssertNil(session.approvalClaim)
            } else {
                XCTAssertEqual(session.state, .working)
                XCTAssertNotNil(session.approvalClaim)
            }
            let stateRequest = try popupCommand(
                subject: "getApprovalState",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                payload: ["mode": "full"]
            )
            let state = await controller.dispatch(
                try popupCommandValue(stateRequest),
                request: stateRequest,
                profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "working")
            XCTAssertNil(state["reviewToken"])
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "release"])
        }
    }

    func testSigningApprovalRequiresCurrentBoundedExecutionDeadline()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 59)
        await store.insert(snapshot)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                .approval(.approveMessage(SignMessageAction(
                    subject: .signMessage,
                    walletId: "wallet",
                    account: popupTestAccount(),
                    meta: "message",
                    resolve: { _ in request.response(error: .internalError) }
                )))
            },
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, _ in
                    XCTFail("Invalid deadline must fail before authentication")
                }
            ),
            loadsTransactionContext: false,
            clock: { now }
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )

        for deadline in [nil, now.addingTimeInterval(-1),
                         now.addingTimeInterval(181)] {
            let approve = try popupCommand(
                subject: "approveRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                reviewToken: token,
                payload: ["revisions": snapshot.revisions.json],
                executionDeadline: deadline
            )
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            XCTAssertEqual(response["status"] as? String, "ignored")
        }
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testMessageApprovalReloadsWalletsAndUsesFreshResolver() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 60, provider: .ethereum)
        await store.insert(snapshot)
        var preparations = 0
        var reloads = 0
        var staleResolves = 0
        var freshResolves = 0
        var events = [String]()
        var authenticationCompletion: ((Bool) -> Void)?
        let processor = CompactPopupProcessor { request in
            preparations += 1
            events.append("prepare\(preparations)")
            let generation = preparations
            return .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    if generation == 1 {
                        staleResolves += 1
                    } else {
                        freshResolves += 1
                    }
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                base: SourcePopupWalletEnvironment(
                    startWalletsManager: { true },
                    reloadWalletsManager: {
                        reloads += 1
                        events.append("reload")
                        return true
                    }
                ),
                authenticate: { _, _, completion in
                    events.append("authenticate")
                    authenticationCompletion = completion
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { authenticationCompletion != nil }
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(reloads, 0)
        authenticationCompletion?(true)
        let response = try await dispatch.value

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(staleResolves, 0)
        XCTAssertEqual(freshResolves, 1)
        XCTAssertEqual(events, ["prepare1", "authenticate", "reload", "prepare2"])
    }

    func testMessageApprovalReleasesClaimWhenAccountDisappears() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 61, provider: .ethereum)
        await store.insert(snapshot)
        var preparations = 0
        var authenticationCount = 0
        var staleResolveCount = 0
        let processor = CompactPopupProcessor { request in
            preparations += 1
            guard preparations == 1 else {
                return .response(request.response(error: .internalError))
            }
            return .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    staleResolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCount += 1
                    completion(true)
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(staleResolveCount, 0)
        let storeEvents = await store.events()
        XCTAssertEqual(storeEvents, ["claim", "release"])
    }

    func testApprovalDispatchAwaitsAuthenticationAndFinalPersistence() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 30)
        await store.insert(snapshot)
        await store.suspendNextCompletion()
        var authenticationCompletion: ((Bool) -> Void)?
        var dispatchCompleted = false
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCompletion = completion
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForCondition { authenticationCompletion != nil }
        XCTAssertFalse(dispatchCompleted)
        let authenticationEvents = await store.events()
        XCTAssertEqual(authenticationEvents, ["claim"])

        authenticationCompletion?(true)
        try await waitForEvent("completeStarted", store: store)
        XCTAssertFalse(dispatchCompleted)

        await store.resumeCompletion()
        let response = try await dispatch.value
        let completionEvents = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(
            completionEvents,
            ["claim", "begin", "completeStarted", "complete"]
        )
    }

    func testExecutionPersistsAfterReviewTokenBecomesStale() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 31)
        await store.insert(snapshot)
        let executionGate = CompactPopupGate()
        var approvalSession: PopupRequestSession?
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    await executionGate.wait()
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { session, _, completion in
                    approvalSession = session
                    completion(true)
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForEvent("begin", store: store)
        try XCTUnwrap(approvalSession).retry()
        await executionGate.open()
        let response = try await dispatch.value
        let events = await store.events()
        let approvalWasCommitted = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "begin", "complete"])
        XCTAssertTrue(approvalWasCommitted)
    }

    func testBroadcastCheckpointsBeforeSendAndCompletion() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 7)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("send")
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 7,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let broadcastEvents = await store.events()
        XCTAssertEqual(
            broadcastEvents,
            ["claim", "begin", "checkpoint", "send", "complete"]
        )
    }

    func testUnlockedWalletAccessIsDroppedBeforeBroadcastSend() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 411)
        await store.insert(snapshot)
        let account = popupTestAccount()
        let catalog = CompactWalletAccess(account: account)
        let processor = CompactPopupAccessProcessor { request, walletAccess in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: account,
                meta: "message",
                resolve: { _ in
                    await store.record(
                        walletAccess.orderedAccounts.isEmpty
                            ? "accessMissingDuringResolve"
                            : "accessPresentDuringResolve"
                    )
                    return .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record(
                                walletAccess.orderedAccounts.isEmpty
                                    ? "accessDroppedBeforeSend"
                                    : "accessRetainedDuringSend"
                            )
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { catalog },
                unlockWalletAccess: { _ in
                    .unlocked(RequestScopedWalletAccess(catalog))
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )

        let events = await store.events()
        XCTAssertEqual(events, [
            "claim",
            "begin",
            "accessPresentDuringResolve",
            "checkpoint",
            "accessDroppedBeforeSend",
            "complete",
        ])
    }

    func testVaultRotationDuringSigningDiscardsPreparedBroadcast()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 415)
        await store.insert(snapshot)
        let account = popupTestAccount()
        let catalog = CompactWalletAccess(account: account)
        var accessIsCurrent = true
        var rotateDuringSigning = true
        let processor = CompactPopupAccessProcessor { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: account,
                meta: "message",
                resolve: { _ in
                    if rotateDuringSigning {
                        accessIsCurrent = false
                    }
                    return .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("broadcastSent")
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { catalog },
                unlockWalletAccess: { _ in
                    .unlocked(RequestScopedWalletAccess(catalog) {
                        accessIsCurrent
                    })
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(events, ["claim", "begin", "rollback"])

        accessIsCurrent = true
        rotateDuringSigning = false
        let retryToken = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let retry = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: retryToken,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(retry),
            request: retry,
            profileIdentifier: nil
        )

        let retryEvents = await store.events()
        XCTAssertEqual(retryEvents, [
            "claim", "begin", "rollback",
            "claim", "begin", "checkpoint", "broadcastSent", "complete",
        ])
    }

    func testProviderRevisionChangeDuringAuthenticationReleasesWithoutSigning()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 419,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 3, solana: 2)
        )
        await store.insert(snapshot)
        let account = popupTestAccount()
        let catalog = CompactWalletAccess(account: account)
        let authenticationGate = CompactPopupGate()
        var authenticationStarted = false
        var resolveCount = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let processor = CompactPopupAccessProcessor { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: account,
                meta: "message",
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .internalError)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { catalog },
                unlockWalletAccess: { _ in
                    authenticationStarted = true
                    await authenticationGate.wait()
                    return .unlocked(RequestScopedWalletAccess(catalog))
                }
            ),
            loadsTransactionContext: false,
            clock: { now }
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let deadline = now.addingTimeInterval(150)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "executionDeadline": Int64(
                    deadline.timeIntervalSince1970 * 1_000
                ),
                "revisions": snapshot.revisions.json,
            ]
        )
        let approval = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { authenticationStarted }
        await store.setRevisions(
            popupRevisions(ethereum: 4, solana: 2),
            handle: snapshot.handle
        )
        await authenticationGate.open()
        _ = try await approval.value

        XCTAssertEqual(resolveCount, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "release"])
    }

    func testVaultAuthenticationCancellationReturnsToReviewWithoutError()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 412)
        await store.insert(snapshot)
        let account = popupTestAccount()
        let catalog = CompactWalletAccess(account: account)
        let processor = CompactPopupAccessProcessor { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: account,
                meta: "message",
                resolve: { _ in
                    XCTFail("Cancellation must not sign")
                    return request.response(error: .internalError)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { catalog },
                unlockWalletAccess: { _ in .canceled }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(events, ["claim", "release"])
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertNil(state["error"])
        XCTAssertNil(state["secureSetupRequired"])
    }

    func testMissingVaultDuringAuthenticationShowsSecureSetupRequired()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 413)
        await store.insert(snapshot)
        let account = popupTestAccount()
        let catalog = CompactWalletAccess(account: account)
        var currentCatalog: WalletAccess? = catalog
        let processor = CompactPopupAccessProcessor { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: account,
                meta: "message",
                resolve: { _ in
                    XCTFail("An unavailable vault must not sign")
                    return request.response(error: .internalError)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { currentCatalog },
                unlockWalletAccess: { _ in
                    currentCatalog = nil
                    return .unavailable
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(events, ["claim", "release"])
        XCTAssertEqual(state["state"] as? String, "error")
        XCTAssertEqual(
            state["error"] as? String,
            Strings.secureApprovalSetupRequired
        )
        XCTAssertEqual(state["secureSetupRequired"] as? Bool, true)
        XCTAssertNil(state["reviewToken"])
    }

    func testChangedVaultDuringAuthenticationReleasesBeforeRematerializing() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 477)
        await store.insert(snapshot)
        let account = popupTestAccount()
        let original = CompactWalletAccess(account: account)
        let replacement = CompactWalletAccess(account: account)
        var currentCatalog: WalletAccess = original
        var preparedCatalogs = [WalletCatalogIdentity]()
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupAccessProcessor { request, access in
                preparedCatalogs.append(access.catalogIdentity)
                return .approval(.approveMessage(SignMessageAction(
                    subject: .signMessage,
                    walletId: "wallet",
                    account: account,
                    meta: "message",
                    resolve: { _ in
                        XCTFail("A changed catalog must be reviewed before signing")
                        return request.response(error: .internalError)
                    }
                )))
            },
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { currentCatalog },
                unlockWalletAccess: { _ in
                    currentCatalog = replacement
                    return .unlocked(RequestScopedWalletAccess(replacement))
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "release"])
        XCTAssertEqual(preparedCatalogs, [original.catalogIdentity])
        let nextToken = try await materializeToken(controller: controller, snapshot: snapshot)
        XCTAssertNotEqual(nextToken, token)
        XCTAssertEqual(preparedCatalogs, [original.catalogIdentity, replacement.catalogIdentity])
    }

    func testCachedSigningAndSelectionReviewsDetectVaultTombstone()
        async throws {
        for (index, isSelection) in [false, true].enumerated() {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: 416 + index)
            await store.insert(snapshot)
            let account = popupTestAccount()
            let catalog = CompactWalletAccess(account: account)
            var currentCatalog: WalletAccess? = catalog
            let processor = CompactPopupAccessProcessor { request, _ in
                if isSelection {
                    return .approval(.selectAccount(SelectAccountAction(
                        coinType: .ethereum,
                        selectedAccounts: [SpecificWalletAccount(
                            walletId: "wallet",
                            account: account
                        )],
                        initiallyConnectedProviders: [],
                        network: popupTransactionNetwork(),
                        resolve: { _, _ in
                            request.response(error: .userRejected)
                        }
                    )))
                }
                return .approval(.approveMessage(SignMessageAction(
                    subject: .signMessage,
                    walletId: "wallet",
                    account: account,
                    meta: "message",
                    resolve: { _ in request.response(error: .internalError) }
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: processor,
                walletEnvironment: VaultPopupWalletEnvironment(
                    catalogAccess: { currentCatalog },
                    unlockWalletAccess: { _ in
                        XCTFail("Unexpected wallet unlock")
                        return .unavailable
                    }
                ),
                loadsTransactionContext: false
            )
            _ = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )
            currentCatalog = nil
            let stateRequest = try popupCommand(
                subject: "getApprovalState",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                payload: ["mode": "full"]
            )

            let state = await controller.dispatch(
                try popupCommandValue(stateRequest),
                request: stateRequest,
                profileIdentifier: nil
            )

            XCTAssertEqual(state["state"] as? String, "error")
            XCTAssertEqual(
                state["error"] as? String,
                Strings.secureApprovalSetupRequired
            )
            XCTAssertEqual(state["secureSetupRequired"] as? Bool, true)
            XCTAssertNil(state["reviewToken"])
        }
    }

    func testCatalogReviewsReloadAccountNamesWithoutRestarting()
        async throws {
        let originalNames = Defaults.walletsAndAccountsNames
        defer {
            Defaults.walletsAndAccountsNames = originalNames
            WalletsMetadataService.reload()
        }
        let account = popupTestAccount()
        let accountKey = "wallet-\(account.coin.rawValue)-\(account.derivationPath)"
        for isSelection in [false, true] {
            let store = CompactPopupStore()
            let catalog = CompactWalletAccess(account: account)
            let processor = CompactPopupAccessProcessor { request, _ in
                if isSelection {
                    return .approval(.selectAccount(SelectAccountAction(
                        coinType: .ethereum,
                        selectedAccounts: Set(catalog.orderedAccounts),
                        initiallyConnectedProviders: [],
                        network: popupTransactionNetwork(),
                        resolve: { _, _ in request.response(error: .userRejected) }
                    )))
                }
                return .approval(.approveMessage(SignMessageAction(
                    subject: .signMessage,
                    walletId: "wallet",
                    account: account,
                    meta: "message",
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: processor,
                walletEnvironment: VaultPopupWalletEnvironment(
                    catalogAccess: { catalog },
                    unlockWalletAccess: { _ in
                        XCTFail("Unexpected wallet unlock")
                        return .unavailable
                    }
                ),
                loadsTransactionContext: false
            )
            let first = try popupSnapshot(id: 418)
            let next = try popupSnapshot(id: 419)
            await store.insert(first)
            await store.insert(next)
            var names = originalNames ?? [:]
            names[accountKey] = "Cached name"
            Defaults.walletsAndAccountsNames = names
            WalletsMetadataService.reload()

            for (index, snapshot) in [first, first, next].enumerated() {
                let expectedName = "Renamed account \(index)"
                names[accountKey] = expectedName
                Defaults.walletsAndAccountsNames = names
                XCTAssertNotEqual(
                    WalletsMetadataService.getAccountName(
                        walletId: "wallet", account: account
                    ),
                    expectedName
                )
                let request = try popupCommand(
                    subject: "getApprovalState",
                    id: snapshot.handle.id,
                    requestToken: snapshot.handle.requestToken,
                    payload: ["mode": "full"]
                )
                let state = await controller.dispatch(
                    try popupCommandValue(request),
                    request: request,
                    profileIdentifier: nil
                )
                let renderedAccount = isSelection
                    ? (state["accounts"] as? [[String: Any]])?.first
                    : state["account"] as? [String: Any]
                XCTAssertEqual(renderedAccount?["name"] as? String, expectedName)
            }
        }
    }

    func testWalletIndependentApprovalDoesNotRequireVaultCatalog()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 414)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor(walletIndependent: true)
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: VaultPopupWalletEnvironment(
                catalogAccess: { nil },
                unlockWalletAccess: { _ in
                    XCTFail("Unexpected wallet unlock")
                    return .unavailable
                }
            ),
            loadsTransactionContext: false
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertEqual(state["kind"] as? String, "addChain")
        XCTAssertNotNil(state["reviewToken"])
        XCTAssertNil(state["secureSetupRequired"])
    }

    func testApprovalDispatchAwaitsBroadcastSend() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 32)
        await store.insert(snapshot)
        let sendGate = CompactPopupGate()
        var dispatchCompleted = false
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("sendStarted")
                            await sendGate.wait()
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForEvent("sendStarted", store: store)
        XCTAssertFalse(dispatchCompleted)
        let pendingEvents = await store.events()
        XCTAssertEqual(
            pendingEvents,
            ["claim", "begin", "checkpoint", "sendStarted"]
        )

        await sendGate.open()
        let response = try await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(
            events,
            ["claim", "begin", "checkpoint", "sendStarted", "complete"]
        )
    }

    func testTransactionApprovalAwaitsSynchronousAuthenticationOutputAndPreflight() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 33, provider: .ethereum)
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var authenticationCompletion: ((Bool) -> Void)?
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        var dispatchCompleted = false
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, completion in
                preflightCompletion = completion
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { transaction in
                    XCTAssertNotNil(transaction)
                    await store.record("resolve")
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCompletion = completion
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForCondition { authenticationCompletion != nil }
        XCTAssertFalse(dispatchCompleted)
        authenticationCompletion?(true)
        try await waitForCondition { preflightCompletion != nil }
        XCTAssertFalse(dispatchCompleted)

        preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
        let response = try await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(events, ["claim", "begin", "resolve", "complete"])
    }

    func testTransactionApprovalUsesFreshResolverAndPreservesExecutionEdits() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 62, provider: .ethereum)
        await store.insert(snapshot)
        let reviewedTransaction = popupReadyTransaction()
        var approvedTransaction = reviewedTransaction
        approvedTransaction.nonce = "0x7"
        approvedTransaction.gas = "0x6000"
        approvedTransaction.replacePreparedFee(
            .legacy(gasPrice: 25),
            provenance: .init(gasPrice: .manual)
        )
        let network = popupTransactionNetwork()
        var preparations = 0
        var staleResolveCount = 0
        var freshResolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, completion in
                completion(.safe(approvedTransaction, popupTransactionEstimate()))
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            preparations += 1
            let generation = preparations
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: reviewedTransaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { transaction in
                    if generation == 1 {
                        staleResolveCount += 1
                    } else {
                        freshResolveCount += 1
                    }
                    XCTAssertEqual(transaction?.nonce, approvedTransaction.nonce)
                    XCTAssertEqual(transaction?.gas, approvedTransaction.gas)
                    XCTAssertEqual(
                        transaction?.preparedFee,
                        approvedTransaction.preparedFee
                    )
                    XCTAssertEqual(
                        transaction?.feeProvenance,
                        approvedTransaction.feeProvenance
                    )
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(staleResolveCount, 0)
        XCTAssertEqual(freshResolveCount, 1)
    }

    func testTransactionApprovalRejectsFreshImmutableDrift() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 63, provider: .ethereum)
        await store.insert(snapshot)
        let reviewedTransaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preparations = 0
        var authenticationCount = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { transaction, _, completion in
                completion(.safe(transaction, popupTransactionEstimate()))
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            preparations += 1
            let transaction: Transaction
            if preparations == 1 {
                transaction = reviewedTransaction
            } else {
                transaction = Transaction(
                    from: reviewedTransaction.from,
                    to: "0x0000000000000000000000000000000000000099",
                    nonce: reviewedTransaction.nonce,
                    gas: reviewedTransaction.gas,
                    value: reviewedTransaction.value,
                    data: reviewedTransaction.data,
                    feeIntent: .legacy(gasPrice: 10),
                    preparedFee: .legacy(gasPrice: 10),
                    feeSource: .automatic
                )
            }
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCount += 1
                    completion(true)
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(resolveCount, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "release"])
    }

    func testTransactionApprovalRejectsFreshRPCEndpointDrift() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 64, provider: .ethereum)
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let reviewedNetwork = popupTransactionNetwork()
        let changedNetwork = EthereumNetwork(
            chainId: reviewedNetwork.chainId,
            name: reviewedNetwork.name,
            symbol: reviewedNetwork.symbol,
            rpcEndpoint: .unauthenticated(
                URL(string: "https://other-rpc.example")!
            ),
            isTestnet: reviewedNetwork.isTestnet,
            mightShowPrice: reviewedNetwork.mightShowPrice,
            explorer: reviewedNetwork.explorer
        )
        var preparations = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { transaction, _, completion in
                completion(.safe(transaction, popupTransactionEstimate()))
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            preparations += 1
            let network = preparations == 1
                ? reviewedNetwork
                : changedNetwork
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(network: network, source: .custom),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    completion(true)
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(resolveCount, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "release"])
    }

    func testTransactionRematerializesAfterRetryableExecutionStartFailure() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 36, provider: .ethereum)
        await store.insert(snapshot)
        await store.failNextBegin()
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { transaction, _, completion in
                completion(.safe(transaction, popupTransactionEstimate()))
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { transaction in
                    XCTAssertNotNil(transaction)
                    resolveCount += 1
                    await store.record("resolve")
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let firstToken = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let firstApproval = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: firstToken,
            payload: ["revisions": snapshot.revisions.json]
        )

        let firstResponse = await controller.dispatch(
            try popupCommandValue(firstApproval),
            request: firstApproval,
            profileIdentifier: nil
        )
        XCTAssertEqual(firstResponse["status"] as? String, "ok")
        let firstEvents = await store.events()
        XCTAssertEqual(firstEvents, ["claim", "begin", "release"])
        XCTAssertEqual(resolveCount, 0)

        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        let secondToken = try XCTUnwrap(state["reviewToken"] as? String)
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertEqual(state["canApprove"] as? Bool, true)
        XCTAssertNotEqual(secondToken, firstToken)

        let secondApproval = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: secondToken,
            payload: ["revisions": snapshot.revisions.json]
        )
        let secondResponse = await controller.dispatch(
            try popupCommandValue(secondApproval),
            request: secondApproval,
            profileIdentifier: nil
        )

        XCTAssertEqual(secondResponse["status"] as? String, "ok")
        XCTAssertEqual(resolveCount, 1)
        let secondEvents = await store.events()
        XCTAssertEqual(
            secondEvents,
            ["claim", "begin", "release", "claim", "begin", "resolve", "complete"]
        )
    }

    func testTransactionPresentationChangeWhileClaimingReturnsToReview() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 35, provider: .ethereum)
        await store.insert(snapshot)
        await store.suspendNextClaim()
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preparationUpdate: ((Transaction) -> Void)?
        var authenticationCount = 0
        var preflightCount = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, onUpdate, _, completion in
                preparationUpdate = onUpdate
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, _ in
                preflightCount += 1
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCount += 1
                    completion(true)
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForEvent("claimStarted", store: store)
        var lateTransaction = transaction
        lateTransaction.interpretation = "Late interpretation"
        preparationUpdate?(lateTransaction)
        await store.resumeClaim()

        let response = try await dispatch.value
        let events = await store.events()
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["status"] as? String, "ignored")
        XCTAssertEqual(events, ["claimStarted", "claim", "release"])
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertEqual(state["dataInterpretation"] as? String, "Late interpretation")
        XCTAssertNotEqual(state["reviewToken"] as? String, token)
        XCTAssertEqual(authenticationCount, 0)
        XCTAssertEqual(preflightCount, 0)
        XCTAssertEqual(resolveCount, 0)
    }

    func testTransactionAlertReleasesClaimBeforeApprovalReturns() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 34, provider: .ethereum)
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, completion in
                preflightCompletion = completion
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { preflightCompletion != nil }
        preflightCompletion?(.unavailable(transaction, popupTransactionEstimate()))
        let response = try await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "release"])

        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertNotNil(state["alert"])
    }

    func testHungBroadcastTimesOutToRecoveryAndInvokesSendOnce() async throws {
        let store = CompactPopupStore()
        let gate = CompactPopupGate()
        let recovered = expectation(description: "recovery before sender returns")
        let late = expectation(description: "sender returned after recovery")
        let snapshot = try popupSnapshot(id: 8)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("send")
                            await gate.wait()
                            await store.record("late")
                            late.fulfill()
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false,
            broadcastTimeoutNanoseconds: 1_000_000
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 8,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let command = try popupCommandValue(approve)
        let task = Task { @MainActor in
            _ = await controller.dispatch(command, request: approve, profileIdentifier: nil)
            recovered.fulfill()
        }
        await fulfillment(of: [recovered], timeout: 1)
        let events = await store.events()
        XCTAssertFalse(events.contains("late"))
        await gate.open()
        await task.value
        await fulfillment(of: [late], timeout: 1)
        XCTAssertEqual(events.filter { $0 == "send" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "complete" }.count, 1)
        let completedErrorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        XCTAssertEqual(completedErrorCode, ProviderResponseError.internalErrorCode)
        let checkpointWasCommitted = await store.checkpointApprovalWasCommitted(
            handle: snapshot.handle
        )
        let completionWasCommitted = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )
        XCTAssertTrue(checkpointWasCommitted)
        XCTAssertTrue(completionWasCommitted)
        let finalEvents = await store.events()
        XCTAssertEqual(finalEvents.filter { $0 == "complete" }.count, 1)
    }

    func testEthereumRevisionMismatchCompletesBeforeAuthenticationOrResolve() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 9,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 3, solana: 4)
        )
        await store.insert(snapshot)
        var authenticationCount = 0
        var resolveCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCount += 1
                    completion(true)
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "revisions": popupRevisions(ethereum: 4, solana: 4).json,
            ]
        )

        let response = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(authenticationCount, 0)
        XCTAssertEqual(resolveCount, 0)
    }

    func testUnrelatedEthereumDriftDoesNotBlockSolanaApproval() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 10,
            provider: .solana,
            revisions: popupRevisions(ethereum: 1, solana: 7)
        )
        await store.insert(snapshot)
        var resolveCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in completion(true) }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "revisions": popupRevisions(ethereum: 99, solana: 7).json,
            ]
        )

        let response = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "begin", "complete"])
        XCTAssertEqual(resolveCount, 1)
    }

    func testUnknownProviderRequiresBothRevisions() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 11,
            revisions: popupRevisions(ethereum: 2, solana: 8)
        )
        await store.insert(snapshot)
        var authenticationCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, completion in
                    authenticationCount += 1
                    completion(true)
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "revisions": popupRevisions(ethereum: 2, solana: 9).json,
            ]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(events, ["complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(authenticationCount, 0)
    }

    func testMissingRevisionsCompletesNonAddApprovalAsStale() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 12, provider: .ethereum)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            walletEnvironment: TestPopupWalletEnvironment(
                authenticate: { _, _, _ in
                    XCTFail("Stale approval must not authenticate")
                }
            ),
            loadsTransactionContext: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )

        let response = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["complete"])
        XCTAssertEqual(errorCode, 4100)
    }

    #if os(macOS)
    func testNativeFinalizerExecutesMatchingDecisionExactlyOnce() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 130,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 4, solana: 2)
        )
        await store.insert(snapshot)
        let account = popupTestAccount()
        let network = popupTransactionNetwork()
        let decision = NativeApprovalDecision.accountSelection(.init(
            accounts: [.init(
                walletID: "wallet",
                address: account.address,
                provider: .ethereum
            )],
            ethereumChainID: network.chainIdHexString
        ))
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: decision
        )
        XCTAssertEqual(staged, .persisted)
        let processor = CompactPopupProcessor { request in
            .approval(.selectAccount(SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: network,
                resolve: { _, accounts in
                    await store.record("resolve")
                    return ResponseToExtension(
                        for: request,
                        payload: .body(.ethereum(.init(
                            results: accounts?.map(\.account.address) ?? [],
                            chainId: network.chainIdHexString
                        )))
                    )
                }
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: { true },
            walletManagerReload: { true },
            accountResolver: { identity in
                guard identity.walletID == "wallet",
                      identity.address == account.address,
                      identity.provider == .ethereum else { return nil }
                return SpecificWalletAccount(walletId: "wallet", account: account)
            },
            networkResolver: { chainID in
                chainID == network.chainIdHexString ? network : nil
            }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot
        )
        let second = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot
        )
        let events = await store.events()
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "resolve", "complete"])
        XCTAssertTrue(committed)
    }

    func testNativeFinalizerProductionPathRequiresLiveExecutionContext()
        async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 138,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 4, solana: 2)
        )
        await store.insert(snapshot)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        let now = Date(timeIntervalSince1970: 2_050_000_000)
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: CompactPopupProcessor(
                walletIndependent: true
            ) { _ in
                .response(request.response(error: .userRejected))
            },
            walletManagerStart: {
                XCTFail("Wallet secrets must not be read before an executable claim")
                return false
            },
            walletManagerReload: {
                XCTFail("Wallet secrets must not be read before an executable claim")
                return false
            },
            clock: { now }
        )

        let missingContext = await finalizer.finalize(handle: snapshot.handle)
        let eventsBeforeContext = await store.events()
        XCTAssertEqual(missingContext, .pending)
        XCTAssertTrue(eventsBeforeContext.isEmpty)

        let context = ExtensionBridge.NativeExecutionContext(
            revisions: snapshot.revisions,
            observedAt: now,
            executionDeadline: now.addingTimeInterval(60),
            fenceToken: UUID()
        )
        await store.installNativeExecutionContext(
            context,
            handle: snapshot.handle
        )
        let result = await finalizer.finalize(handle: snapshot.handle)
        let second = await finalizer.finalize(handle: snapshot.handle)
        let events = await store.events()

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "complete"])
    }

    func testNativeFinalizerKeepsLiveReceiptPendingWhenExecutionContextIsLost()
        async throws {
        let store = CompactPopupStore()
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try popupSnapshot(
            id: 172,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 4, solana: 2),
            nativeDeliveryReceipt: .init(
                nativeDeliveryNonce: nonce,
                runtimeInstanceIdentifier: runtime,
                owner: popupNativeDeliveryOwner
            )
        )
        await store.insert(snapshot)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        let now = Date(timeIntervalSince1970: 2_060_000_000)
        let context = ExtensionBridge.NativeExecutionContext(
            revisions: snapshot.revisions,
            observedAt: now,
            executionDeadline: now.addingTimeInterval(60),
            fenceToken: UUID()
        )
        await store.installNativeExecutionContext(
            context,
            handle: snapshot.handle
        )
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: CompactPopupProcessor(
                walletIndependent: true
            ) { _ in
                .approval(.approveMessage(SignMessageAction(
                    subject: .signMessage,
                    walletId: "wallet",
                    account: popupTestAccount(),
                    meta: "message",
                    resolve: { _ in
                        await store.installNativeExecutionContext(
                            .init(
                                revisions: snapshot.revisions,
                                observedAt: now,
                                executionDeadline: now.addingTimeInterval(60),
                                fenceToken: UUID()
                            ),
                            handle: snapshot.handle
                        )
                        return request.response(error: .userRejected)
                    }
                )))
            },
            walletManagerStart: { true },
            walletManagerReload: { true },
            clock: { now }
        )

        let result = await finalizer.finalize(handle: snapshot.handle)
        guard case .found(let retained) = await store.load(
            handle: snapshot.handle
        ) else { return XCTFail("Expected retained approval") }
        let completedErrorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        let events = await store.events()

        XCTAssertEqual(result, .pending)
        XCTAssertEqual(retained.phase, .approving)
        XCTAssertEqual(
            retained.nativeDeliveryReceipt?.nativeDeliveryNonce,
            nonce
        )
        XCTAssertEqual(
            retained.nativeDeliveryReceipt?.runtimeInstanceIdentifier,
            runtime
        )
        XCTAssertNil(completedErrorCode)
        XCTAssertEqual(events, ["nativeClaim", "begin"])
    }

    func testNativeFinalizerRejectsChangedReviewedRPCEndpoint() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 139,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 4, solana: 2)
        )
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let reviewedNetwork = ResolvedEthereumNetwork(
            network: popupTransactionNetwork(),
            source: .custom
        )
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: reviewedNetwork
            )
        )
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .transaction(execution)
        )
        XCTAssertEqual(staged, .persisted)
        let changedNetwork = EthereumNetwork(
            chainId: reviewedNetwork.network.chainId,
            name: reviewedNetwork.network.name,
            symbol: reviewedNetwork.network.symbol,
            rpcEndpoint: .unauthenticated(
                URL(string: "https://other-rpc.example")!
            ),
            isTestnet: reviewedNetwork.network.isTestnet,
            mightShowPrice: reviewedNetwork.network.mightShowPrice,
            explorer: reviewedNetwork.network.explorer
        )
        let request = try XCTUnwrap(snapshot.request)
        var resolveCount = 0
        let processor = CompactPopupProcessor { _ in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(
                    network: changedNetwork,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return .response(request.response(error: .userRejected))
                }
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: { true },
            walletManagerReload: { true }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot
        )
        let errorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        let events = await store.events()
        XCTAssertEqual(events, [
            "nativeClaim", "begin", "complete",
        ])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRetriesStagedDecisionAfterWalletStartFailure() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 136,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 4, solana: 2)
        )
        await store.insert(snapshot)
        let account = popupTestAccount()
        let network = popupTransactionNetwork()
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .accountSelection(.init(
                accounts: [.init(
                    walletID: "wallet",
                    address: account.address,
                    provider: .ethereum
                )],
                ethereumChainID: network.chainIdHexString
            ))
        )
        XCTAssertEqual(staged, .persisted)
        var starts = 0
        var reloads = 0
        var preparations = 0
        var resolves = 0
        let processor = CompactPopupProcessor { request in
            preparations += 1
            return .approval(.selectAccount(SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: network,
                resolve: { _, accounts in
                    resolves += 1
                    await store.record("resolve")
                    return ResponseToExtension(
                        for: request,
                        payload: .body(.ethereum(.init(
                            results: accounts?.map(\.account.address) ?? [],
                            chainId: network.chainIdHexString
                        )))
                    )
                }
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: {
                starts += 1
                return false
            },
            walletManagerReload: {
                reloads += 1
                return true
            },
            accountResolver: { identity in
                guard identity.walletID == "wallet",
                      identity.address == account.address,
                      identity.provider == .ethereum else { return nil }
                return SpecificWalletAccount(walletId: "wallet", account: account)
            },
            networkResolver: { chainID in
                chainID == network.chainIdHexString ? network : nil
            }
        )

        let first = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot
        )
        guard case .found(let retained) = await store.load(
            handle: snapshot.handle
        ) else { return XCTFail("Expected retained staged decision") }
        let firstErrorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        let firstEvents = await store.events()

        XCTAssertEqual(first, .pending)
        XCTAssertEqual(retained.phase, .queued)
        XCTAssertTrue(retained.nativeDecisionStaged)
        XCTAssertNil(firstErrorCode)
        XCTAssertEqual(firstEvents, ["nativeClaim", "release"])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(resolves, 0)

        let second = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot
        )
        let finalEvents = await store.events()
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(resolves, 1)
        XCTAssertEqual(finalEvents, [
            "nativeClaim", "release", "nativeClaim", "begin", "resolve",
            "complete",
        ])
        XCTAssertTrue(committed)
    }

    func testNativeFinalizerWalletRetryPreservesTransactionFreshness() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 137,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        )
        await store.insert(snapshot)
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                popupReadyTransaction(),
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                )
            )
        )
        var now = Date(timeIntervalSince1970: 2_400_000_000)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .transaction(execution),
            stagedAt: now
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        var preparations = 0
        var reloads = 0
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: CompactPopupProcessor { _ in
                preparations += 1
                XCTFail("Expired retry must not rematerialize")
                return .response(request.response(error: .internalError))
            },
            walletManagerStart: { false },
            walletManagerReload: {
                reloads += 1
                return true
            },
            clock: { now }
        )

        let first = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        now = now.addingTimeInterval(
            NativeApprovalFinalizer.maximumTransactionDecisionAge + 1
        )
        let second = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )
        let events = await store.events()

        XCTAssertEqual(first, .pending)
        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(errorCode, 4100)
        XCTAssertFalse(committed)
        XCTAssertEqual(events, [
            "nativeClaim", "release", "nativeClaim", "begin", "complete",
        ])
    }

    func testNativeFinalizerWalletRetryPreservesRevisionLineage() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 138,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 3, solana: 8)
        )
        await store.insert(snapshot)
        let account = popupTestAccount()
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .accountSelection(.init(
                accounts: [.init(
                    walletID: "wallet",
                    address: account.address,
                    provider: .ethereum
                )],
                ethereumChainID: nil
            ))
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        var preparations = 0
        var reloads = 0
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: CompactPopupProcessor { _ in
                preparations += 1
                XCTFail("Revision-drifted retry must not rematerialize")
                return .response(request.response(error: .internalError))
            },
            walletManagerStart: { false },
            walletManagerReload: {
                reloads += 1
                return true
            }
        )

        let first = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot
        )
        let second = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            revisions: popupRevisions(ethereum: 4, solana: 8)
        )
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )
        let events = await store.events()

        XCTAssertEqual(first, .pending)
        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(errorCode, 4100)
        XCTAssertFalse(committed)
        XCTAssertEqual(events, [
            "nativeClaim", "release", "nativeClaim", "begin", "complete",
        ])
    }

    func testNativeFinalizerRevisionMismatchCompletesBeforeResolve() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 131,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 3, solana: 8)
        )
        await store.insert(snapshot)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .message(.init(solanaCluster: nil))
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        let processor = CompactPopupProcessor { _ in
            XCTFail("Revision mismatch must not rematerialize or resolve")
            return .response(ResponseToExtension(
                for: request,
                payload: .error(.internalError)
            ))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: { true },
            walletManagerReload: { true }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            revisions: popupRevisions(ethereum: 4, solana: 8)
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRejectsExpiredTransactionDecisionBeforeResolve() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 132,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        )
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                )
            )
        )
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .transaction(execution),
            stagedAt: now.addingTimeInterval(
                -NativeApprovalFinalizer.maximumTransactionDecisionAge - 1
            )
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        let processor = CompactPopupProcessor { _ in
            XCTFail("Expired transaction decision must not rematerialize or resolve")
            return .response(ResponseToExtension(
                for: request,
                payload: .error(.internalError)
            ))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: { true },
            walletManagerReload: { true },
            clock: { now }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRejectsFutureTransactionDecisionBeforeResolve() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 133,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        )
        await store.insert(snapshot)
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                popupReadyTransaction(),
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                )
            )
        )
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .transaction(execution),
            stagedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: CompactPopupProcessor { _ in
                XCTFail("Future transaction decision must not be prepared")
                return .response(request.response(error: .internalError))
            },
            walletManagerStart: { true },
            walletManagerReload: { true },
            clock: { now }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRejectsExpiredSolanaTransactionDecisions() async throws {
        let methods = [
            "signTransaction",
            "signAllTransactions",
            "signAndSendTransaction",
        ]
        let now = Date(timeIntervalSince1970: 2_150_000_000)
        for (offset, method) in methods.enumerated() {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(
                id: 140 + offset,
                provider: .solana,
                method: method,
                revisions: popupRevisions(ethereum: 1, solana: 2)
            )
            await store.insert(snapshot)
            let staged = await store.stageNativeDecision(
                handle: snapshot.handle,
                decision: .message(.init(solanaCluster: nil)),
                stagedAt: now.addingTimeInterval(
                    -NativeApprovalFinalizer.maximumTransactionDecisionAge - 1
                )
            )
            XCTAssertEqual(staged, .persisted, method)
            let request = try XCTUnwrap(snapshot.request)
            let finalizer = NativeApprovalFinalizer(
                store: store,
                requestProcessor: CompactPopupProcessor { _ in
                    XCTFail("Expired \(method) decision must not be prepared")
                    return .response(request.response(error: .internalError))
                },
                walletManagerStart: { true },
                walletManagerReload: { true },
                clock: { now }
            )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
            let errorCode = await store.completedErrorCode(
                handle: snapshot.handle
            )
            let committed = await store.completedApprovalWasCommitted(
                handle: snapshot.handle
            )
            XCTAssertEqual(result, .responseReady, method)
            XCTAssertEqual(errorCode, 4100, method)
            XCTAssertFalse(committed, method)
        }
    }

    func testNativeFinalizerRejectsFutureSolanaTransactionDecisions() async throws {
        let methods = [
            "signTransaction",
            "signAllTransactions",
            "signAndSendTransaction",
        ]
        let now = Date(timeIntervalSince1970: 2_160_000_000)
        for (offset, method) in methods.enumerated() {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(
                id: 150 + offset,
                provider: .solana,
                method: method,
                revisions: popupRevisions(ethereum: 1, solana: 2)
            )
            await store.insert(snapshot)
            let staged = await store.stageNativeDecision(
                handle: snapshot.handle,
                decision: .message(.init(solanaCluster: nil)),
                stagedAt: now.addingTimeInterval(1)
            )
            XCTAssertEqual(staged, .persisted, method)
            let request = try XCTUnwrap(snapshot.request)
            let finalizer = NativeApprovalFinalizer(
                store: store,
                requestProcessor: CompactPopupProcessor { _ in
                    XCTFail("Future \(method) decision must not be prepared")
                    return .response(request.response(error: .internalError))
                },
                walletManagerStart: { true },
                walletManagerReload: { true },
                clock: { now }
            )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
            let errorCode = await store.completedErrorCode(
                handle: snapshot.handle
            )
            XCTAssertEqual(result, .responseReady, method)
            XCTAssertEqual(errorCode, 4100, method)
        }
    }

    func testNativeFinalizerDoesNotAgeOrdinarySolanaMessageSigning() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 160,
            provider: .solana,
            method: "signMessage",
            revisions: popupRevisions(ethereum: 1, solana: 2)
        )
        await store.insert(snapshot)
        let now = Date(timeIntervalSince1970: 2_170_000_000)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .message(.init(solanaCluster: nil)),
            stagedAt: now.addingTimeInterval(
                -NativeApprovalFinalizer.maximumTransactionDecisionAge - 1
            )
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        var resolveCount = 0
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: CompactPopupProcessor { _ in
                .approval(.approveMessage(SignMessageAction(
                    subject: .signMessage,
                    walletId: "wallet",
                    account: popupTestAccount(),
                    meta: "message",
                    resolve: { _ in
                        resolveCount += 1
                        return request.response(error: .userRejected)
                    }
                )))
            },
            walletManagerStart: { true },
            walletManagerReload: { true },
            clock: { now }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )
        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(resolveCount, 1)
        XCTAssertTrue(committed)
    }

    func testNativeFinalizerRechecksTransactionAgeAfterPreparation() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 134,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        )
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                )
            )
        )
        var now = Date(timeIntervalSince1970: 2_200_000_000)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .transaction(execution),
            stagedAt: now
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        var resolveCount = 0
        let network = popupTransactionNetwork()
        let processor = CompactPopupProcessor { _ in
            now = now.addingTimeInterval(
                NativeApprovalFinalizer.maximumTransactionDecisionAge + 1
            )
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(network: network, source: .custom),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return .response(request.response(error: .userRejected))
                }
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: { true },
            walletManagerReload: { true },
            clock: { now }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRechecksTransactionAgeAfterBegin() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 135,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        )
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let execution = try XCTUnwrap(
            NativeApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                )
            )
        )
        var now = Date(timeIntervalSince1970: 2_300_000_000)
        let staged = await store.stageNativeDecision(
            handle: snapshot.handle,
            decision: .transaction(execution),
            stagedAt: now
        )
        XCTAssertEqual(staged, .persisted)
        let request = try XCTUnwrap(snapshot.request)
        var resolveCount = 0
        let network = popupTransactionNetwork()
        let processor = CompactPopupProcessor { _ in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(network: network, source: .custom),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return .response(request.response(error: .userRejected))
                }
            )))
        }
        await store.setBeginHook {
            now = now.addingTimeInterval(
                NativeApprovalFinalizer.maximumTransactionDecisionAge + 1
            )
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            requestProcessor: processor,
            walletManagerStart: { true },
            walletManagerReload: { true },
            clock: { now }
        )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "begin", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRechecksSolanaTransactionAgeBeforeExecution() async throws {
        for advancesAtBegin in [false, true] {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(
                id: advancesAtBegin ? 171 : 170,
                provider: .solana,
                method: "signTransaction",
                revisions: popupRevisions(ethereum: 1, solana: 2)
            )
            await store.insert(snapshot)
            var now = Date(timeIntervalSince1970: 2_350_000_000)
            let staged = await store.stageNativeDecision(
                handle: snapshot.handle,
                decision: .message(.init(solanaCluster: nil)),
                stagedAt: now
            )
            XCTAssertEqual(staged, .persisted)
            let request = try XCTUnwrap(snapshot.request)
            var resolveCount = 0
            let processor = CompactPopupProcessor { _ in
                if !advancesAtBegin {
                    now = now.addingTimeInterval(
                        NativeApprovalFinalizer.maximumTransactionDecisionAge + 1
                    )
                }
                return .approval(.approveMessage(SignMessageAction(
                    subject: .approveTransaction,
                    walletId: "wallet",
                    account: popupTestAccount(),
                    meta: "transaction",
                    resolve: { _ in
                        resolveCount += 1
                        return request.response(error: .userRejected)
                    }
                )))
            }
            if advancesAtBegin {
                await store.setBeginHook {
                    now = now.addingTimeInterval(
                        NativeApprovalFinalizer.maximumTransactionDecisionAge + 1
                    )
                }
            }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                requestProcessor: processor,
                walletManagerStart: { true },
                walletManagerReload: { true },
                clock: { now }
            )

        let result = await finalizeNativeDecision(
            finalizer,
            store: store,
            snapshot: snapshot,
            observedAt: now
        )
            let errorCode = await store.completedErrorCode(
                handle: snapshot.handle
            )
            let committed = await store.completedApprovalWasCommitted(
                handle: snapshot.handle
            )
            XCTAssertEqual(result, .responseReady)
            XCTAssertEqual(resolveCount, 0)
            XCTAssertEqual(errorCode, 4100)
            XCTAssertFalse(committed)
        }
    }

    func testNativeAgentLauncherSerializesConcurrentRoutes() async throws {
        let helperURL = URL(fileURLWithPath: "/tmp/Big Wallet Launcher Test.app")
        var activeResolutions = 0
        var maximumActiveResolutions = 0
        var resolutionCount = 0
        var confirmationCount = 0
        var deliveredRoutes = [URL]()
        var events = [String]()
        let resolutionEntered = CompactPopupGate()
        let releaseResolution = CompactPopupGate()
        let handle = ExtensionBridge.Handle(
            id: 401,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
        let walletRoute = NativeAgentRoute.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        )
        let approvalRoute = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: handle,
            nativeDeliveryNonce: .init(value: UUID())
        )
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                events.append("resolve")
                activeResolutions += 1
                maximumActiveResolutions = max(
                    maximumActiveResolutions,
                    activeResolutions
                )
                resolutionCount += 1
                await resolutionEntered.open()
                await releaseResolution.wait()
                try? await Task.sleep(nanoseconds: 300_000_000)
                activeResolutions -= 1
                return .running(
                    url: url,
                    processIdentifier: 1,
                    runtimeInstanceIdentifier: UUID()
                )
            },
            confirm: { _, route, _, _ in
                events.append(
                    route == walletRoute ? "confirm-wallet" :
                        "confirm-approval"
                )
                confirmationCount += 1
                return true
            },
            existingDelivery: { route, _ in
                events.append(
                    route == walletRoute ? "preflight-wallet" :
                        "preflight-approval"
                )
                return .needsDelivery
            },
            launchTimeoutNanoseconds: 1_000_000_000,
            launch: { _, route, completion in
                events.append(
                    route == walletRoute.url ? "send-wallet" :
                        "send-approval"
                )
                deliveredRoutes.append(route)
                completion(true)
            }
        )
        let walletOpen = Task { await launcher.open(walletRoute) }
        await resolutionEntered.wait()
        let approvalOpen = Task { await launcher.open(approvalRoute) }
        await Task.yield()
        await releaseResolution.open()
        let results = await (walletOpen.value, approvalOpen.value)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(maximumActiveResolutions, 1)
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(confirmationCount, 2)
        XCTAssertEqual(deliveredRoutes, [
            walletRoute.url,
            approvalRoute.url,
        ])
        XCTAssertEqual(events, [
            "preflight-wallet", "resolve", "send-wallet", "confirm-wallet",
            "preflight-approval", "resolve", "send-approval",
            "confirm-approval",
        ])
    }

    func testQueuedNativeAgentDeliveryGetsFreshDeadlineAfterCallerTimesOut()
        async throws {
        let helperURL = URL(
            fileURLWithPath: "/tmp/Big Wallet Fresh Deadline Test.app"
        )
        let walletRoute = NativeAgentRoute.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        )
        let approvalRoute = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: ExtensionBridge.Handle(
                id: 405,
                token: .init(value: UUID()),
                profileIdentifier: nil
            ),
            nativeDeliveryNonce: .init(value: UUID())
        )
        let firstResolutionEntered = CompactPopupGate()
        let releaseFirstResolution = CompactPopupGate()
        let approvalDelivered = expectation(
            description: "queued approval delivered with a fresh deadline"
        )
        var resolutionCount = 0
        var deliveredRoutes = [URL]()
        var events = [String]()
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                resolutionCount += 1
                events.append("resolve-\(resolutionCount)")
                if resolutionCount == 1 {
                    await firstResolutionEntered.open()
                    await releaseFirstResolution.wait()
                }
                return .running(
                    url: url,
                    processIdentifier: 1,
                    runtimeInstanceIdentifier: UUID()
                )
            },
            confirm: { _, route, _, _ in
                events.append(route == approvalRoute ? "confirm-approval" :
                    "confirm-wallet")
                return true
            },
            existingDelivery: { route, _ in
                events.append(route == approvalRoute ? "preflight-approval" :
                    "preflight-wallet")
                return .needsDelivery
            },
            launchTimeoutNanoseconds: 100_000_000,
            launch: { _, route, completion in
                deliveredRoutes.append(route)
                events.append(route == approvalRoute.url ? "send-approval" :
                    "send-wallet")
                completion(true)
                if route == approvalRoute.url {
                    approvalDelivered.fulfill()
                }
            }
        )
        let first = Task { await launcher.open(walletRoute) }
        await firstResolutionEntered.wait()
        let second = Task { await launcher.open(approvalRoute) }

        try await Task.sleep(nanoseconds: 150_000_000)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        await releaseFirstResolution.open()
        await fulfillment(of: [approvalDelivered], timeout: 1)

        XCTAssertEqual(deliveredRoutes, [approvalRoute.url])
        XCTAssertEqual(events, [
            "preflight-wallet", "resolve-1",
            "preflight-approval", "resolve-2", "send-approval",
            "confirm-approval",
        ])
    }

    func testNativeAgentLauncherCoalescesIdenticalRoutes() async throws {
        let helperURL = URL(
            fileURLWithPath: "/tmp/Big Wallet Coalesced Launcher Test.app"
        )
        let route = NativeAgentRoute.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        )
        let resolutionEntered = CompactPopupGate()
        let releaseResolution = CompactPopupGate()
        var resolutionCount = 0
        var launchCount = 0
        var confirmationCount = 0
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                resolutionCount += 1
                await resolutionEntered.open()
                await releaseResolution.wait()
                return .running(
                    url: url,
                    processIdentifier: 1,
                    runtimeInstanceIdentifier: UUID()
                )
            },
            confirm: { _, _, _, _ in
                confirmationCount += 1
                return true
            },
            launch: { _, _, completion in
                launchCount += 1
                completion(true)
            }
        )
        let first = Task { await launcher.open(route) }
        await resolutionEntered.wait()
        let second = Task { await launcher.open(route) }
        await Task.yield()
        await releaseResolution.open()

        let results = await (first.value, second.value)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(resolutionCount, 1)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(confirmationCount, 1)
    }

    func testNativeAgentLauncherRetriesAfterSharedDeliveryFailsAndCoalescesThirdCaller()
        async {
        let helperURL = URL(
            fileURLWithPath: "/tmp/Big Wallet Shared Retry Test.app"
        )
        let route = NativeAgentRoute.showWallet(
            workflowVersion: ExtensionBridge.workflowVersion
        )
        let resolutionEntered = CompactPopupGate()
        let releaseResolution = CompactPopupGate()
        var resolutionCount = 0
        var launchCount = 0
        var confirmationCount = 0
        let launcher = NativeAgentLauncher(
            helperURL: { helperURL },
            validate: { _ in true },
            resolveHelper: { url, _, _ in
                resolutionCount += 1
                await resolutionEntered.open()
                await releaseResolution.wait()
                return .running(
                    url: url,
                    processIdentifier: 1,
                    runtimeInstanceIdentifier: UUID()
                )
            },
            confirm: { _, _, _, _ in
                confirmationCount += 1
                return confirmationCount == 4
            },
            launch: { _, _, completion in
                launchCount += 1
                completion(true)
            }
        )
        let first = Task { await launcher.open(route) }
        await resolutionEntered.wait()
        let second = Task { await launcher.open(route) }
        let third = Task { await launcher.open(route) }
        await Task.yield()
        await Task.yield()
        await releaseResolution.open()

        let results = await (first.value, second.value, third.value)

        XCTAssertFalse(results.0)
        XCTAssertTrue(results.1)
        XCTAssertTrue(results.2)
        XCTAssertEqual(resolutionCount, 4)
        XCTAssertEqual(launchCount, 4)
        XCTAssertEqual(confirmationCount, 4)
    }

    func testNativeAgentLauncherDoesNotReactivateDeliveredApproval() async {
        let helperURL = URL(
            fileURLWithPath: "/tmp/Big Wallet Delivered Approval.app"
        )
        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: ExtensionBridge.Handle(
                id: 402,
                token: .init(value: UUID()),
                profileIdentifier: nil
            ),
            nativeDeliveryNonce: .init(value: UUID())
        )
        var helperLookupCount = 0
        var validationCount = 0
        var resolutionCount = 0
        var launchCount = 0
        var confirmationCount = 0
        let launcher = NativeAgentLauncher(
            helperURL: {
                helperLookupCount += 1
                return helperURL
            },
            validate: { _ in
                validationCount += 1
                return true
            },
            resolveHelper: { url, _, _ in
                resolutionCount += 1
                return .launch(
                    url: url,
                    createsNewApplicationInstance: false
                )
            },
            confirm: { _, _, _, _ in
                confirmationCount += 1
                return false
            },
            existingDelivery: { deliveredRoute, _ in
                XCTAssertEqual(deliveredRoute, route)
                return .delivered
            },
            launch: { _, _, completion in
                launchCount += 1
                completion(true)
            }
        )

        let opened = await launcher.open(route)
        XCTAssertTrue(opened)
        XCTAssertEqual(helperLookupCount, 0)
        XCTAssertEqual(validationCount, 0)
        XCTAssertEqual(resolutionCount, 0)
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(confirmationCount, 0)
    }

    func testNativeAgentLauncherDoesNotLaunchWhenOwnershipIsUnavailable() async {
        let helperURL = URL(
            fileURLWithPath: "/tmp/Big Wallet Unavailable Approval.app"
        )
        let route = NativeAgentRoute.approval(
            workflowVersion: ExtensionBridge.workflowVersion,
            handle: ExtensionBridge.Handle(
                id: 403,
                token: .init(value: UUID()),
                profileIdentifier: nil
            ),
            nativeDeliveryNonce: .init(value: UUID())
        )
        var helperLookupCount = 0
        var validationCount = 0
        var resolutionCount = 0
        var launchCount = 0
        var confirmationCount = 0
        let launcher = NativeAgentLauncher(
            helperURL: {
                helperLookupCount += 1
                return helperURL
            },
            validate: { _ in
                validationCount += 1
                return true
            },
            resolveHelper: { url, _, _ in
                resolutionCount += 1
                return .launch(
                    url: url,
                    createsNewApplicationInstance: false
                )
            },
            confirm: { _, _, _, _ in
                confirmationCount += 1
                return false
            },
            existingDelivery: { _, _ in .unavailable },
            launch: { _, _, completion in
                launchCount += 1
                completion(true)
            }
        )

        let opened = await launcher.open(route)
        XCTAssertFalse(opened)
        XCTAssertEqual(helperLookupCount, 0)
        XCTAssertEqual(validationCount, 0)
        XCTAssertEqual(resolutionCount, 0)
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(confirmationCount, 0)
    }

    func testNativeAgentConfirmationUsesProcessStartWhenLaunchDateIsNil() throws {
        let bundleURL = try makePopupLauncherBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let processIdentifier = Int32(8_108)
        let processStartDate = Date(timeIntervalSince1970: 3_000)
        let identity = try popupLauncherRuntimeIdentity(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            launchDate: processStartDate
        )
        let validRuntime = NativeAgentLauncher.RuntimeHelper(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            processStartDate: processStartDate,
            isRunning: { true }
        )
        let reusedPIDRuntime = NativeAgentLauncher.RuntimeHelper(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            processStartDate: processStartDate.addingTimeInterval(1),
            isRunning: { true }
        )

        XCTAssertTrue(NativeAgentLauncher.isConfirmedRuntimeHelper(
            validRuntime,
            expectedURL: bundleURL,
            identity: { _ in identity },
            validate: { $0 == bundleURL.standardizedFileURL }
        ))
        XCTAssertFalse(NativeAgentLauncher.isConfirmedRuntimeHelper(
            reusedPIDRuntime,
            expectedURL: bundleURL,
            identity: { _ in identity },
            validate: { _ in
                XCTFail("A replaced process must not reach code verification")
                return true
            }
        ))
    }

    func testNativeAgentQuitDoesNotTargetReusedProcessIdentifier() {
        let capturedStartDate = Date(timeIntervalSince1970: 1_000)
        var targetedProcessIdentifier: Int32?

        XCTAssertTrue(NativeAgentLauncher.requestExactReceiptOwnerQuit(
            processIdentifier: 8_111,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: { _ in
                capturedStartDate.addingTimeInterval(1)
            },
            sendQuitEvent: { processIdentifier in
                targetedProcessIdentifier = processIdentifier
                return true
            }
        ))
        XCTAssertNil(targetedProcessIdentifier)
    }

    func testNativeAgentQuitTargetsOnlyTheRevalidatedProcess() {
        let capturedStartDate = Date(timeIntervalSince1970: 1_000)
        var targetedProcessIdentifier: Int32?

        XCTAssertTrue(NativeAgentLauncher.requestExactReceiptOwnerQuit(
            processIdentifier: 8_112,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: { _ in capturedStartDate },
            sendQuitEvent: { processIdentifier in
                targetedProcessIdentifier = processIdentifier
                return true
            }
        ))
        XCTAssertEqual(targetedProcessIdentifier, 8_112)
    }

    func testNativeAgentCannotQuitWithoutCapturedProcessStart() {
        var targetedProcessIdentifier: Int32?

        XCTAssertFalse(NativeAgentLauncher.requestExactReceiptOwnerQuit(
            processIdentifier: 8_115,
            capturedStartDate: nil,
            runningProcessStartDate: { _ in Date() },
            sendQuitEvent: { processIdentifier in
                targetedProcessIdentifier = processIdentifier
                return true
            }
        ))
        XCTAssertNil(targetedProcessIdentifier)
    }

    func testNativeAgentFailsClosedWhenProcessStartLookupBecomesUnavailable() {
        let capturedStartDate = Date(timeIntervalSince1970: 1_000)
        var targetedProcessIdentifier: Int32?

        XCTAssertFalse(NativeAgentLauncher.requestExactReceiptOwnerQuit(
            processIdentifier: 8_114,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: { _ in nil },
            sendQuitEvent: { processIdentifier in
                targetedProcessIdentifier = processIdentifier
                return true
            }
        ))
        XCTAssertTrue(NativeAgentLauncher.runtimeProcessIsRunning(
            processIdentifier: 8_114,
            capturedStartDate: capturedStartDate,
            isTerminated: false,
            runningProcessStartDate: { _ in nil }
        ))
        XCTAssertNil(targetedProcessIdentifier)
    }

    func testNativeAgentTreatsUnidentifiedLiveProcessAsRunning() {
        XCTAssertTrue(NativeAgentLauncher.runtimeProcessIsRunning(
            processIdentifier: 8_113,
            capturedStartDate: nil,
            isTerminated: false,
            runningProcessStartDate: { _ in nil }
        ))
    }

    func testRuntimeIdentityRejectsLaunchDateWithoutProcessStart() throws {
        let bundleURL = try makePopupLauncherBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let launchedAt = Date(timeIntervalSince1970: 4_000)
        let identity = try popupLauncherRuntimeIdentity(
            processIdentifier: 8_109,
            bundleURL: bundleURL,
            launchDate: launchedAt
        )

        XCTAssertFalse(identity.matches(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            runningProcessStartDate: { _ in nil }
        ))
    }

    func testRuntimeIdentityPrefersLiveProcessStartOverLaunchDate() throws {
        let bundleURL = try makePopupLauncherBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let launchedAt = Date(timeIntervalSince1970: 5_000)
        let identity = try popupLauncherRuntimeIdentity(
            processIdentifier: 8_110,
            bundleURL: bundleURL,
            launchDate: launchedAt
        )

        XCTAssertFalse(identity.matches(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            runningProcessStartDate: { _ in
                launchedAt.addingTimeInterval(1)
            }
        ))
        XCTAssertTrue(identity.matches(
            processIdentifier: identity.processIdentifier,
            bundleURL: bundleURL,
            runningProcessStartDate: { _ in launchedAt }
        ))
    }

    func testNativeAgentLaunchConfigurationIsPrivateAndCopyIsolated() {
        let configuration = NativeAgentLauncher.applicationLaunchConfiguration(
            createsNewApplicationInstance: true
        )

        XCTAssertTrue(configuration.activates)
        XCTAssertFalse(configuration.addsToRecentItems)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
    }

    func testSafariSandboxAllowsAppleEventsOnlyToAmbient() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Safari macOS/Safari.entitlements"
        ))
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(
            entitlements[
                "com.apple.security.temporary-exception.apple-events"
            ] as? [String],
            ["org.lil.wallet.ambient"]
        )

        let infoData = try Data(contentsOf: root.appendingPathComponent(
            "Safari macOS/Info.plist"
        ))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: infoData,
                format: nil
            ) as? [String: Any]
        )
        XCTAssertFalse(
            (info["NSAppleEventsUsageDescription"] as? String)?.isEmpty ?? true
        )
    }

    private func finalizeNativeDecision(
        _ finalizer: NativeApprovalFinalizer,
        store: CompactPopupStore,
        snapshot: ExtensionBridge.Snapshot,
        revisions: ExtensionBridge.ProviderRevisions? = nil,
        observedAt: Date = Date()
    ) async -> NativeApprovalFinalizationResult {
        await store.installNativeExecutionContext(
            .init(
                revisions: revisions ?? snapshot.revisions,
                observedAt: observedAt,
                executionDeadline: observedAt.addingTimeInterval(120),
                fenceToken: UUID()
            ),
            handle: snapshot.handle
        )
        return await finalizer.finalize(handle: snapshot.handle)
    }
    #endif

    private func popupController(store: CompactPopupStore) -> PopupRequestSessions {
        return PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor(),
            walletEnvironment: TestPopupWalletEnvironment(),
            loadsTransactionContext: false
        )
    }

    private func materializeToken(
        controller: PopupRequestSessions,
        snapshot: ExtensionBridge.Snapshot
    ) async throws -> String {
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        return try XCTUnwrap(state["reviewToken"] as? String)
    }

    private func waitForEvent(
        _ event: String,
        store: CompactPopupStore
    ) async throws {
        for _ in 0..<100 {
            if await store.events().contains(event) { return }
            await Task.yield()
        }
        throw PopupRequestSessionsTestError.timedOut
    }

    private func waitForCondition(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        throw PopupRequestSessionsTestError.timedOut
    }
}

@MainActor
private final class CompactPopupProcessor: PopupRequestProcessing {
    let handler: (SafariRequest) -> DappRequestPreparation
    let walletIndependent: Bool

    init(
        walletIndependent: Bool = false,
        handler: @escaping (SafariRequest) -> DappRequestPreparation = { request in
            .approval(.addEthereumChain(AddEthereumChainAction(
                chainToAdd: popupTestNetwork(),
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
    ) {
        self.walletIndependent = walletIndependent
        self.handler = handler
    }

    func prepare(_ request: SafariRequest) -> DappRequestPreparation {
        return handler(request)
    }

    func prepareWithoutWallets(
        _ request: SafariRequest
    ) -> DappRequestPreparation? {
        walletIndependent ? handler(request) : nil
    }
}

@MainActor
private final class CompactPopupAccessProcessor: PopupRequestProcessing {
    let handler: (SafariRequest, WalletAccess) -> DappRequestPreparation

    init(handler: @escaping (SafariRequest, WalletAccess) -> DappRequestPreparation) {
        self.handler = handler
    }

    func prepare(_ request: SafariRequest) -> DappRequestPreparation {
        handler(request, SourceWalletAccess.shared)
    }

    func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        handler(request, walletAccess)
    }
}

private final class CompactWalletAccess: WalletAccess {
    let catalogIdentity = WalletCatalogIdentity(
        generation: UUID(),
        sourceRevision: 1,
        catalogData: Data("catalog".utf8)
    )
    let orderedAccounts: [SpecificWalletAccount]

    init(account: WalletAccount) {
        orderedAccounts = [SpecificWalletAccount(
            walletId: "wallet",
            account: account
        )]
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        nil
    }
}

private actor CompactPopupGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private final class CompactExecutionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class CompactExecutionLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var held = true
    private var heldAtDurableCommit = false
    private var releasedBeforeBroadcast = false

    var wasHeldAtDurableCommit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldAtDurableCommit
    }

    var wasReleasedBeforeBroadcast: Bool {
        lock.lock()
        defer { lock.unlock() }
        return releasedBeforeBroadcast
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !held
    }

    func observeDurableCommit() {
        lock.lock()
        heldAtDurableCommit = heldAtDurableCommit || held
        lock.unlock()
    }

    func observeBroadcast() {
        lock.lock()
        releasedBeforeBroadcast = !held
        lock.unlock()
    }

    func release() {
        lock.lock()
        held = false
        lock.unlock()
    }
}

private actor CompactPopupStore: NativeApprovalStore {
    private let clock: @Sendable () -> Date
    private var records = [ExtensionBridge.Handle: ExtensionBridge.Snapshot]()
    private var eventValues = [String]()
    private var claims = [ExtensionBridge.Handle: ExtensionBridge.ApprovalClaim]()
    private var permits = [ExtensionBridge.Handle: ExtensionBridge.ExecutionPermit]()
    private var permitRequests = [ExtensionBridge.Handle: SafariRequest]()
    private var nativeDecisions = [
        ExtensionBridge.Handle: NativeApprovalDecision
    ]()
    private var nativeDecisionStagedDates = [ExtensionBridge.Handle: Date]()
    private var nativeExecutionContexts = [
        ExtensionBridge.Handle: ExtensionBridge.NativeExecutionContext
    ]()
    private var completedErrorCodes = [ExtensionBridge.Handle: Int]()
    private var committedCompletions = Set<ExtensionBridge.Handle>()
    private var committedCheckpoints = Set<ExtensionBridge.Handle>()
    private var nextRejectResult: ExtensionBridge.StoreMutationResult?
    private var nextReleaseResult: ExtensionBridge.StoreMutationResult?
    private var nextCompletionOwnershipReceipt:
        ExtensionBridge.NativeDeliveryReceipt?
    private var shouldFailNextBegin = false
    private var beginHook: (@MainActor () -> Void)?
    private var permitCompletionHook: (@Sendable () -> Void)?
    private var broadcastCheckpointHook: (@Sendable () -> Void)?
    private var suspendClaim = false
    private var claimContinuation: CheckedContinuation<Void, Never>?
    private var suspendCompletion = false
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private var loadCountValue = 0

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    func insert(_ snapshot: ExtensionBridge.Snapshot) { records[snapshot.handle] = snapshot }

    func setNativeDeliveryReceipt(
        _ receipt: ExtensionBridge.NativeDeliveryReceipt?,
        handle: ExtensionBridge.Handle
    ) {
        guard let snapshot = records[handle] else { return }
        records[handle] = replacingNativeDeliveryReceipt(
            snapshot,
            receipt: receipt
        )
    }

    func setRevisions(
        _ revisions: ExtensionBridge.ProviderRevisions,
        handle: ExtensionBridge.Handle
    ) {
        guard let snapshot = records[handle] else { return }
        records[handle] = replacing(
            snapshot,
            phase: snapshot.phase,
            request: snapshot.request,
            revisions: revisions
        )
    }

    func events() -> [String] { eventValues }
    func loadCount() -> Int { loadCountValue }
    func record(_ event: String) { eventValues.append(event) }
    func installNativeExecutionContext(
        _ context: ExtensionBridge.NativeExecutionContext,
        handle: ExtensionBridge.Handle
    ) {
        nativeExecutionContexts[handle] = context
    }
    func completedErrorCode(handle: ExtensionBridge.Handle) -> Int? {
        return completedErrorCodes[handle]
    }
    func completedApprovalWasCommitted(
        handle: ExtensionBridge.Handle
    ) -> Bool {
        return committedCompletions.contains(handle)
    }
    func checkpointApprovalWasCommitted(
        handle: ExtensionBridge.Handle
    ) -> Bool {
        return committedCheckpoints.contains(handle)
    }
    func forceNextRejectResult(_ result: ExtensionBridge.StoreMutationResult) {
        nextRejectResult = result
    }
    func forceNextReleaseResult(_ result: ExtensionBridge.StoreMutationResult) {
        nextReleaseResult = result
    }
    func forceNextCompletionOwnershipLoss(
        receipt: ExtensionBridge.NativeDeliveryReceipt
    ) {
        nextCompletionOwnershipReceipt = receipt
    }
    func failNextBegin() { shouldFailNextBegin = true }
    func setBeginHook(_ hook: @escaping @MainActor () -> Void) {
        beginHook = hook
    }
    func setPermitCompletionHook(_ hook: @escaping @Sendable () -> Void) {
        permitCompletionHook = hook
    }
    func setBroadcastCheckpointHook(_ hook: @escaping @Sendable () -> Void) {
        broadcastCheckpointHook = hook
    }
    func suspendNextClaim() { suspendClaim = true }
    func resumeClaim() {
        let continuation = claimContinuation
        claimContinuation = nil
        continuation?.resume()
    }
    func suspendNextCompletion() { suspendCompletion = true }
    func resumeCompletion() {
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume()
    }

    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult {
        .available(records.filter { $0.key.profileIdentifier == profileIdentifier })
    }

    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult {
        loadCountValue += 1
        return records[handle].map(ExtensionBridge.SnapshotResult.found) ?? .missing
    }

    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult {
        if suspendClaim {
            suspendClaim = false
            await withCheckedContinuation { continuation in
                eventValues.append("claimStarted")
                claimContinuation = continuation
            }
        }
        guard let snapshot = records[handle], snapshot.phase == .queued else { return .missing }
        guard !snapshot.nativeDecisionStaged else { return .executing }
        eventValues.append("claim")
        let claim = ExtensionBridge.ApprovalClaim(handle: handle, value: UUID())
        claims[handle] = claim
        records[handle] = replacing(snapshot, phase: .approving, request: snapshot.request)
        return .claimed(claim)
    }

    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        decision: NativeApprovalDecision
    ) async -> ExtensionBridge.StoreMutationResult {
        return stageNativeDecision(
            handle: handle,
            decision: decision,
            stagedAt: Date()
        )
    }

    func stageNativeDecision(
        handle: ExtensionBridge.Handle,
        decision: NativeApprovalDecision,
        stagedAt: Date
    ) -> ExtensionBridge.StoreMutationResult {
        guard let snapshot = records[handle], snapshot.phase == .queued else {
            return .ownershipLost
        }
        if let existing = nativeDecisions[handle] {
            return existing == decision ? .persisted : .ownershipLost
        }
        nativeDecisions[handle] = decision
        nativeDecisionStagedDates[handle] = stagedAt
        records[handle] = replacing(
            snapshot,
            phase: .queued,
            request: snapshot.request,
            nativeDecisionStaged: true
        )
        return .persisted
    }

    func claimExecutableNativeDecision(
        handle: ExtensionBridge.Handle
    ) async -> ExtensionBridge.NativeDecisionClaimResult {
        guard let snapshot = records[handle] else { return .missing }
        switch snapshot.phase {
        case .queued:
            guard let context = nativeExecutionContexts[handle],
                  let decision = nativeDecisions[handle] else {
                return .notStaged
            }
            guard let stagedAt = nativeDecisionStagedDates[handle] else {
                return .unavailable
            }
            eventValues.append("nativeClaim")
            let claim = ExtensionBridge.ApprovalClaim(
                handle: handle,
                value: UUID()
            )
            claims[handle] = claim
            records[handle] = replacing(
                snapshot,
                phase: .approving,
                request: snapshot.request,
                nativeDecisionStaged: true
            )
            return .claimed(.init(
                approvalClaim: claim,
                decision: decision,
                stagedAt: stagedAt,
                executionContext: context
            ))
        case .approving:
            return .executing
        case .responded:
            return .responded
        }
    }

    func complete(handle: ExtensionBridge.Handle, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult {
        completedErrorCodes[handle] = response.json["errorCode"] as? Int
        if let receipt = nextCompletionOwnershipReceipt,
           let snapshot = records[handle] {
            nextCompletionOwnershipReceipt = nil
            records[handle] = replacingNativeDeliveryReceipt(
                snapshot,
                receipt: receipt
            )
            return .ownershipLost
        }
        return await complete(handle: handle)
    }

    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult {
        eventValues.append("reject")
        if let result = nextRejectResult {
            nextRejectResult = nil
            return result
        }
        return await complete(handle: handle, recordsEvent: false)
    }

    func release(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult {
        guard claims[claim.handle] == claim, let snapshot = records[claim.handle] else {
            return .ownershipLost
        }
        eventValues.append("release")
        if let result = nextReleaseResult {
            nextReleaseResult = nil
            return result
        }
        claims[claim.handle] = nil
        records[claim.handle] = replacing(snapshot, phase: .queued, request: snapshot.request)
        return .persisted
    }

    func begin(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.BeginExecutionResult {
        guard claims[claim.handle] == claim, let snapshot = records[claim.handle] else {
            return .ownershipLost
        }
        eventValues.append("begin")
        await beginHook?()
        if shouldFailNextBegin {
            shouldFailNextBegin = false
            return .retryablePersistenceFailure
        }
        let permit = ExtensionBridge.ExecutionPermit(handle: claim.handle, value: UUID())
        claims[claim.handle] = nil
        permits[claim.handle] = permit
        permitRequests[claim.handle] = snapshot.request
        records[claim.handle] = replacing(snapshot, phase: .approving, request: nil)
        return .began(permit)
    }

    func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) async -> ExtensionBridge.StoreMutationResult {
        permitCompletionHook?()
        guard permits[permit.handle] == permit,
              executionAuthorityAuthorizes(
                  handle: permit.handle,
                  authority: authority
              ) else {
            return .ownershipLost
        }
        permits[permit.handle] = nil
        permitRequests[permit.handle] = nil
        completedErrorCodes[permit.handle] = response.json["errorCode"] as? Int
        if response.json[ExtensionBridge.approvalCommittedKey] as? Bool == true {
            committedCompletions.insert(permit.handle)
        }
        return await complete(handle: permit.handle)
    }

    func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension,
        authority: ExtensionBridge.ExecutionAuthority
    ) async -> ExtensionBridge.StoreMutationResult {
        broadcastCheckpointHook?()
        guard permits[permit.handle] == permit,
              executionAuthorityAuthorizes(
                  handle: permit.handle,
                  authority: authority
              ) else {
            return .ownershipLost
        }
        if recoveryResponse.json[ExtensionBridge.approvalCommittedKey] as? Bool == true {
            committedCheckpoints.insert(permit.handle)
        }
        eventValues.append("checkpoint")
        nativeExecutionContexts[permit.handle] = nil
        return .persisted
    }

    func rollback(
        permit: ExtensionBridge.ExecutionPermit
    ) async -> ExtensionBridge.StoreMutationResult {
        guard permits[permit.handle] == permit,
              let snapshot = records[permit.handle],
              let request = permitRequests[permit.handle] else {
            return .ownershipLost
        }
        permits[permit.handle] = nil
        permitRequests[permit.handle] = nil
        records[permit.handle] = replacing(
            snapshot,
            phase: .queued,
            request: request
        )
        eventValues.append("rollback")
        return .persisted
    }

    private func executionAuthorityAuthorizes(
        handle: ExtensionBridge.Handle,
        authority: ExtensionBridge.ExecutionAuthority
    ) -> Bool {
        switch authority {
        case .ordinary:
            return nativeExecutionContexts[handle] == nil
        case .mobileSigning(let deadline):
            return nativeExecutionContexts[handle] == nil && clock() < deadline
        case .native(let expected):
            return nativeExecutionContexts[handle] == expected
        }
    }

    private func complete(
        handle: ExtensionBridge.Handle,
        recordsEvent: Bool = true
    ) async -> ExtensionBridge.StoreMutationResult {
        guard let snapshot = records[handle] else { return .ownershipLost }
        if suspendCompletion {
            suspendCompletion = false
            await withCheckedContinuation { continuation in
                eventValues.append("completeStarted")
                completionContinuation = continuation
            }
        }
        if recordsEvent { eventValues.append("complete") }
        nativeDecisions[handle] = nil
        nativeDecisionStagedDates[handle] = nil
        nativeExecutionContexts[handle] = nil
        records[handle] = replacing(
            snapshot,
            phase: .responded,
            request: nil,
            nativeDecisionStaged: false,
            clearsNativeDeliveryReceipt: true
        )
        return .persisted
    }

    private func replacing(
        _ snapshot: ExtensionBridge.Snapshot,
        phase: ExtensionBridge.Phase,
        request: SafariRequest?,
        nativeDecisionStaged: Bool? = nil,
        clearsNativeDeliveryReceipt: Bool = false,
        revisions: ExtensionBridge.ProviderRevisions? = nil
    ) -> ExtensionBridge.Snapshot {
        ExtensionBridge.Snapshot(
            handle: snapshot.handle,
            phase: phase,
            request: request,
            nativeDecisionStaged: nativeDecisionStaged ??
                snapshot.nativeDecisionStaged,
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            nativeDeliveryReceipt: clearsNativeDeliveryReceipt
                ? nil
                : snapshot.nativeDeliveryReceipt,
            host: snapshot.host,
            configurationKey: snapshot.configurationKey,
            revisions: revisions ?? snapshot.revisions,
            createdAt: snapshot.createdAt,
            enqueueAttempt: snapshot.enqueueAttempt,
            sequence: snapshot.sequence
        )
    }

    private func replacingNativeDeliveryReceipt(
        _ snapshot: ExtensionBridge.Snapshot,
        receipt: ExtensionBridge.NativeDeliveryReceipt?
    ) -> ExtensionBridge.Snapshot {
        ExtensionBridge.Snapshot(
            handle: snapshot.handle,
            phase: snapshot.phase,
            request: snapshot.request,
            nativeDecisionStaged: snapshot.nativeDecisionStaged,
            nativeDeliveryNonce: receipt?.nativeDeliveryNonce ??
                snapshot.nativeDeliveryNonce,
            nativeDeliveryReceipt: receipt,
            host: snapshot.host,
            configurationKey: snapshot.configurationKey,
            revisions: snapshot.revisions,
            createdAt: snapshot.createdAt,
            enqueueAttempt: snapshot.enqueueAttempt,
            sequence: snapshot.sequence
        )
    }
}

private extension SafariRequest {
    func response(error: ProviderResponseError) -> ResponseToExtension {
        ResponseToExtension(for: self, payload: .error(error))
    }
}

private func popupTestNetwork() -> EthereumNetworkFromDapp {
    EthereumNetworkFromDapp(
        chainId: "0x1234",
        rpcUrls: ["https://rpc.example"],
        blockExplorerUrls: [],
        nativeCurrency: .init(decimals: 18, name: "Test Ether", symbol: "TETH"),
        chainName: "Test Network"
    )
}

private func popupTestAccount() -> WalletAccount {
    WalletAccount(
        address: "0x0000000000000000000000000000000000000042",
        coin: .ethereum,
        derivation: .default,
        derivationPath: "m/44'/60'/0'/0/0",
        publicKey: "",
        extendedPublicKey: ""
    )
}

private func popupReadyTransaction() -> Transaction {
    Transaction(
        from: "0x0000000000000000000000000000000000000001",
        to: "0x0000000000000000000000000000000000000002",
        nonce: "0x0",
        gas: "0x5208",
        value: "0x0",
        data: "0x",
        feeIntent: .legacy(gasPrice: 10),
        preparedFee: .legacy(gasPrice: 10),
        feeSource: .automatic
    )
}

private func popupTransactionNetwork() -> EthereumNetwork {
    EthereumNetwork(
        chainId: 10,
        name: "Test",
        symbol: "ETH",
        rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
        isTestnet: true,
        mightShowPrice: false,
        explorer: nil
    )
}

private func popupTransactionEstimate() -> GasService.Estimate {
    GasService.Estimate(
        info: nil,
        nextBaseFee: nil,
        currentBaseFee: nil,
        support: .legacy,
        gasPrice: 10,
        endpointChainID: 10
    )
}

private func popupSwitchSnapshot(
    id: Int,
    address: String,
    requestedChainId: String = "0x1"
) throws -> ExtensionBridge.Snapshot {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "name": "switchEthereumChain",
        "provider": "ethereum",
        "host": "wallet.example",
        "configurationKey": "wallet.example",
        "enqueueAttempt": String(format: "%032x", id),
        "admissionDeadline": popupRequestAdmissionDeadline,
        "workflowVersion": ExtensionBridge.workflowVersion,
        "body": [
            "address": address,
            "chainId": "0x1",
            "object": ["chainId": requestedChainId],
        ],
    ])
    let request = try XCTUnwrap(SafariRequest(data: data))
    let handle = ExtensionBridge.Handle(
        id: id,
        token: .init(value: UUID()),
        profileIdentifier: nil
    )
    return ExtensionBridge.Snapshot(
        handle: handle,
        phase: .queued,
        request: request,
        nativeDecisionStaged: false,
        host: request.host,
        configurationKey: request.configurationKey,
        revisions: popupRevisions(),
        createdAt: Date(),
        enqueueAttempt: request.enqueueAttempt,
        sequence: id
    )
}

private func popupSnapshot(
    id: Int,
    createdAt: Date = Date(),
    provider: InpageProvider = .unknown,
    method: String? = nil,
    revisions: ExtensionBridge.ProviderRevisions = popupRevisions(),
    phase: ExtensionBridge.Phase = .queued,
    nativeDecisionStaged: Bool = false,
    nativeDeliveryReceipt: ExtensionBridge.NativeDeliveryReceipt? = nil
) throws -> ExtensionBridge.Snapshot {
    let name: String
    let body: [String: Any]
    switch provider {
    case .ethereum:
        name = method ?? "requestAccounts"
        if name == "signTransaction" {
            body = [
                "address": popupTestAccount().address,
                "chainId": "0x1",
                "object": [
                    "to":
                        "0x0000000000000000000000000000000000000002",
                ],
            ]
        } else {
            body = ["address": popupTestAccount().address]
        }
    case .solana:
        name = method ?? "connect"
        body = [
            "publicKey": "solana-public-key",
            "object": ["params": [String: Any]()],
        ]
    case .unknown:
        name = "switchAccount"
        body = ["latestConfigurations": []]
    case .multiple:
        throw CocoaError(.coderInvalidValue)
    }
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "name": name,
        "provider": provider.rawValue,
        "host": "wallet.example",
        "configurationKey": "wallet.example",
        "enqueueAttempt": String(format: "%032x", id),
        "admissionDeadline": popupRequestAdmissionDeadline,
        "workflowVersion": ExtensionBridge.workflowVersion,
        "body": body,
    ])
    let request = try XCTUnwrap(SafariRequest(data: data))
    let handle = ExtensionBridge.Handle(
        id: id,
        token: .init(value: UUID()),
        profileIdentifier: nil
    )
    return ExtensionBridge.Snapshot(
        handle: handle,
        phase: phase,
        request: phase == .responded ? nil : request,
        nativeDecisionStaged: nativeDecisionStaged,
        nativeDeliveryNonce: nativeDeliveryReceipt?.nativeDeliveryNonce,
        nativeDeliveryReceipt: nativeDeliveryReceipt,
        host: request.host,
        configurationKey: request.configurationKey,
        revisions: revisions,
        createdAt: createdAt,
        enqueueAttempt: request.enqueueAttempt,
        sequence: id
    )
}

private func popupRevisions(
    ethereum: Int = 0,
    solana: Int = 0
) -> ExtensionBridge.ProviderRevisions {
    guard let revisions = ExtensionBridge.ProviderRevisions(rawValue: [
        "ethereum": ethereum,
        "solana": solana,
    ]) else {
        preconditionFailure("Invalid test revisions")
    }
    return revisions
}

#if os(macOS)
private func makePopupLauncherBundle(build: String = "148") throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("popup-launcher-\(UUID().uuidString)")
        .appendingPathExtension("app")
    let contentsURL = bundleURL.appendingPathComponent(
        "Contents",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: contentsURL,
        withIntermediateDirectories: true
    )
    let info: [String: Any] = [
        "CFBundleIdentifier": "org.lil.wallet.ambient",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0.99",
        "CFBundleVersion": build,
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try data.write(
        to: contentsURL.appendingPathComponent("Info.plist"),
        options: .atomic
    )
    return bundleURL
}

private func popupLauncherRuntimeIdentity(
    processIdentifier: Int32,
    bundleURL: URL,
    launchDate: Date
) throws -> AmbientRuntimeIdentity {
    AmbientRuntimeIdentity(
        instanceIdentifier: UUID(),
        processIdentifier: processIdentifier,
        bundlePath: bundleURL.standardizedFileURL.path,
        version: try XCTUnwrap(
            AmbientRuntimeIdentity.bundleVersion(at: bundleURL)
        ),
        runtimeProtocolVersion:
            AmbientRuntimeIdentity.currentRuntimeProtocolVersion,
        supportedWorkflowVersions: [ExtensionBridge.workflowVersion],
        launchedAt: launchDate
    )
}
#endif

private func popupCommand(
    subject: String,
    id: Int,
    requestToken: String? = nil,
    reviewToken: String? = nil,
    payload: [String: Any]? = nil,
    executionDeadline: Date? = Date().addingTimeInterval(150)
) throws -> InternalSafariRequest {
    var payload = payload
    if subject == "approveRequest",
       payload?["executionDeadline"] == nil,
       let executionDeadline {
        payload?["executionDeadline"] = Int64(
            executionDeadline.timeIntervalSince1970 * 1_000
        )
    }
    var value: [String: Any] = [
        "subject": subject,
        "id": id,
        "workflowVersion": ExtensionBridge.workflowVersion,
    ]
    value["requestToken"] = requestToken
    value["reviewToken"] = reviewToken
    value["payload"] = payload
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(InternalSafariRequest.self, from: data)
}

private func popupCommandValue(
    _ request: InternalSafariRequest
) throws -> InternalSafariRequest.PopupCommand {
    guard case .popup(let command) = request.command else {
        throw CocoaError(.coderInvalidValue)
    }
    return command
}

@MainActor
private final class TestPopupWalletEnvironment: PopupWalletEnvironment {
    private let base: PopupWalletEnvironment?
    private let refresh: (() -> Bool)?
    private let resolve: ((InternalSafariRequest.SelectedAccount) -> SpecificWalletAccount?)?
    private let authenticate: ((PopupRequestSession, String, @escaping (Bool) -> Void) -> Void)?

    init(
        base: PopupWalletEnvironment? = nil,
        refresh: (() -> Bool)? = nil,
        resolve: ((InternalSafariRequest.SelectedAccount) -> SpecificWalletAccount?)? = nil,
        authenticate: ((PopupRequestSession, String, @escaping (Bool) -> Void) -> Void)? = nil
    ) {
        self.base = base
        self.refresh = refresh
        self.resolve = resolve
        self.authenticate = authenticate
    }

    var reviewPolicy: PopupWalletReviewPolicy {
        base?.reviewPolicy ?? .liveSource
    }

    func prepareForNewSession() -> WalletAccess? {
        if let base { return base.prepareForNewSession() }
        return SourceWalletAccess.shared
    }

    func currentReviewAccess() -> WalletAccess? {
        if let base { return base.currentReviewAccess() }
        return SourceWalletAccess.shared
    }

    func refreshWallets() -> Bool {
        if let refresh { return refresh() }
        return base?.refreshWallets() ?? true
    }

    func resolveSelectedAccount(
        _ item: InternalSafariRequest.SelectedAccount,
        reviewedAccess: WalletAccess
    ) -> SpecificWalletAccount? {
        if let resolve { return resolve(item) }
        return (base ?? SourcePopupWalletEnvironment()).resolveSelectedAccount(
            item,
            reviewedAccess: reviewedAccess
        )
    }

    func unlock(
        for session: PopupRequestSession,
        reason: String
    ) async -> WalletUnlockResult {
        guard let authenticate else {
            if let base { return await base.unlock(for: session, reason: reason) }
            return .canceled
        }
        let succeeded = await withCheckedContinuation { continuation in
            var completed = false
            authenticate(session, reason) { succeeded in
                guard !completed else { return }
                completed = true
                continuation.resume(returning: succeeded)
            }
        }
        guard succeeded, let access = session.walletAccess else { return .canceled }
        return .unlocked(RequestScopedWalletAccess(access))
    }
}

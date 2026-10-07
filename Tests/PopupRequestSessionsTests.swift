// ∅ 2026 lil org

import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

private func popupNativeDeliveryOwner(runtime: UUID = UUID()) -> ExtensionBridge.NativeDeliveryOwner {
    ExtensionBridge.NativeDeliveryOwner(
        runtimeInstanceIdentifier: runtime,
        processIdentifier: 42,
        processStartDate: Date(timeIntervalSince1970: 1_800_000_000),
        bundleURL: URL(fileURLWithPath: "/tmp/Big Wallet.app"),
        marketingVersion: "1.0.99",
        buildVersion: "148"
    )!
}

private let popupRequestAdmissionDeadline = 2_000_000_900_000

private enum PopupRequestSessionsTestError: Error {
    case timedOut
}

private final class PopupPreparationSource: Sendable {
    let stream: AsyncThrowingStream<TransactionPreparationEvent, Error>
    private let continuation: AsyncThrowingStream<TransactionPreparationEvent, Error>.Continuation

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func update(_ transaction: Transaction) { continuation.yield(.transactionUpdated(transaction)) }
    func estimate(_ estimate: GasService.Estimate) { continuation.yield(.feeEstimate(estimate)) }
    func resolve(_ result: Result<Transaction, TransactionPreparationFailure>) {
        switch result {
        case .success(let transaction): continuation.yield(.ready(transaction))
        case .failure(let error): continuation.finish(throwing: error)
        }
    }
}

private final class PopupCancellationRecorder: Sendable {
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

private final class PopupPreflightSource: Sendable {
    private struct State {
        var result: TransactionFeePreflightResult?
        var continuation: CheckedContinuation<TransactionFeePreflightResult, Error>?
        var resolved = false
    }
    private let state = Mutex(State())

    func resolve(_ result: TransactionFeePreflightResult) {
        let continuation = state.withLock { state in
            guard !state.resolved else { return CheckedContinuation<TransactionFeePreflightResult, Error>?.none }
            state.resolved = true
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil { state.result = result }
            return continuation
        }
        continuation?.resume(returning: result)
    }

    func value(cancellation: PopupCancellationRecorder? = nil) async throws -> TransactionFeePreflightResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let result: TransactionFeePreflightResult? = state.withLock { state in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(returning: result) }
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            cancellation?.cancel()
            self.cancel()
        }
    }

    private func cancel() {
        let continuation = state.withLock { state in
            state.resolved = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

func unusedPopupTransactionOperations() -> TransactionApprovalOperations {
    TransactionApprovalOperations(
        prepare: { _, _, _ in
            let source = PopupPreparationSource()
            XCTFail("A nontransaction review must not prepare a transaction")
            return source.stream
        },
        preflight: { _, _ in
            let source = PopupPreflightSource()
            XCTFail("A nontransaction review must not preflight a transaction")
            return try await source.value(cancellation: nil)
        }
    )
}

@MainActor
final class PopupRequestSessionsTests: XCTestCase {

    func testCommandRepliesCarryCurrentStateWithoutAnotherRead() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 701, provider: .ethereum, method: "addEthereumChain"), in: store)
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor()
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let stale = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: UUID().uuidString.lowercased(),
            payload: [:]
        )
        let ignored = popupResponseJSON(await controller.dispatch(request: stale, profileIdentifier: nil))
        XCTAssertEqual(Set(ignored.keys), ["status", "approval"])
        XCTAssertEqual(ignored["status"] as? String, "ignored")
        let current = try XCTUnwrap(ignored["approval"] as? [String: Any])
        XCTAssertEqual(current["state"] as? String, "review")
        XCTAssertEqual((current["review"] as? [String: Any])?["reviewToken"] as? String, token)
        let reject = try popupCommand(
            subject: "rejectRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let completed = popupResponseJSON(await controller.dispatch(request: reject, profileIdentifier: nil))
        XCTAssertEqual(completed["status"] as? String, "ok")
        XCTAssertEqual((completed["approval"] as? [String: Any])?["state"] as? String, "missing")
        let pending = await controller.dispatchJSON(
            request: try popupCommand(subject: "getPendingRequests", id: 702),
            profileIdentifier: nil
        )
        XCTAssertEqual((pending["completedResponses"] as? [[String: Any]])?.count, 1)
    }

    func testTransactionResponsesOwnLoadingPresentationAndTransientEditFeedback() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 705, provider: .ethereum, method: "signTransaction"), in: store)
        let transaction = popupReadyTransaction()
        let action = SendTransactionAction(
            transaction: transaction,
            resolvedNetwork: ResolvedEthereumNetwork(network: popupTransactionNetwork(), source: .custom),
            walletId: "wallet", account: popupTestAccount()
        )
        var finishPreparation: ((Result<Transaction, TransactionPreparationFailure>) -> Void)?
        var preparationInput: Transaction?
        var preparationUpdate: ((Transaction) -> Void)?
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            transactionApprovalOperations: TransactionApprovalOperations(
                prepare: { incoming, _, _ in
                    let source = PopupPreparationSource()
                    preparationInput = incoming
                    preparationUpdate = source.update
                    finishPreparation = source.resolve
                    return source.stream
                },
                preflight: { _, _ in
                    let source = PopupPreflightSource()

                    return try await source.value(cancellation: nil)
                }
            ),
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { _ in .approval(.approveTransaction(action)) }
            )
        )
        let read = try popupCommand(
            subject: "getApprovalState", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let preparing = await controller.dispatchJSON(request: read, profileIdentifier: nil)
        let preparingReview = try XCTUnwrap(preparing["review"] as? [String: Any])
        XCTAssertNil(preparingReview["phase"])
        XCTAssertEqual(preparingReview["canBackOffRefresh"] as? Bool, false)
        XCTAssertEqual((preparingReview["feeLines"] as? [String])?.last, Strings.calculating.withEllipsis)

        let complete = try XCTUnwrap(finishPreparation)
        let prepared = popupPreparedTransaction(try XCTUnwrap(preparationInput))
        preparationUpdate?(prepared)
        complete(.success(prepared))
        let ready = await controller.dispatchJSON(request: read, profileIdentifier: nil)
        let readyReview = try XCTUnwrap(ready["review"] as? [String: Any])
        XCTAssertNil(readyReview["phase"])
        XCTAssertEqual(readyReview["canBackOffRefresh"] as? Bool, true)
        XCTAssertFalse((readyReview["feeLines"] as? [String] ?? []).contains(Strings.calculating.withEllipsis))
        let token = try XCTUnwrap(readyReview["reviewToken"] as? String)
        let edits = try popupCommand(
            subject: "applyTransactionEdits", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token,
            payload: ["mode": "custom", "nonce": "1", "gasPriceGwei": "invalid"]
        )
        let invalid = popupResponseJSON(await controller.dispatch(request: edits, profileIdentifier: nil))
        XCTAssertEqual(Set(invalid.keys), ["status", "approval", "editsError"])
        XCTAssertEqual(invalid["status"] as? String, "ok")
        XCTAssertEqual(invalid["editsError"] as? Bool, true)
        let unchanged = try XCTUnwrap(invalid["approval"] as? [String: Any])
        XCTAssertNil(unchanged["editsError"])
        XCTAssertEqual(unchanged as NSDictionary, ready.json.filter { $0.key != "status" } as NSDictionary)
        let refreshed = popupResponseJSON(await controller.dispatch(request: read, profileIdentifier: nil))
        XCTAssertEqual(Set(refreshed.keys), ["status", "approval"])
        XCTAssertEqual(refreshed["approval"] as? NSDictionary, unchanged as NSDictionary)
    }

    func testPrivatePopupCommandsNeverExposeStoredReview() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 703, provider: .ethereum, method: "addEthereumChain"), in: store)
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor()
            )
        )
        _ = try await materializeToken(controller: controller, snapshot: snapshot)
        let reads = await store.loadCount()
        for subject in ["getApprovalState", "retryApproval", "rejectRequest"] {
            let command = try popupCommand(
                subject: subject, id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            let reply = popupResponseJSON(controller.privateBrowsingResponse(for: command))
            XCTAssertEqual(Set(reply.keys), ["status", "approval"])
            XCTAssertEqual(reply["status"] as? String, "ignored")
            XCTAssertTrue(reply["approval"] is NSNull)
        }
        let readsAfter = await store.loadCount()
        XCTAssertEqual(readsAfter, reads)
    }

    func testUnavailableStoreNeverLooksLikeCompletedRequest() async throws {
        let store = try ApprovalStoreTestFixture()
        addTeardownBlock { try? await store.cleanup() }
        let snapshot = try await enqueue(popupSnapshot(id: 704, provider: .ethereum, method: "addEthereumChain"), in: store)
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor()
            )
        )
        try await store.cleanup()
        for subject in ["getApprovalState", "retryApproval", "rejectRequest"] {
            let command = try popupCommand(
                subject: subject, id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            let reply = popupResponseJSON(await controller.dispatch(request: command, profileIdentifier: nil))
            XCTAssertEqual(reply["status"] as? String, "unavailable")
            XCTAssertTrue(reply["approval"] is NSNull)
        }
    }

    func testRequestScopeInvalidatesOwnedAccessOnceWithoutClearingBorrowedCatalog() {
        for explicitlyInvalidate in [false, true] {
            let catalog = WalletReviewCatalog(account: popupTestAccount())
            let owned = BorrowedWalletSignerForTesting()
            var scoped: WalletSigningSession? = WalletSigningSession(
                owned,
                authorization: walletSigningAuthorizationForTesting(approvedAccount: popupTestAccountDescriptor()),
                isCurrent: { true },
                acquireCommitLease: { WalletExecutionLease(release: {}) }
            )
            weak let scopedReference = scoped

            XCTAssertTrue(scoped?.validateCurrent() == true)
            if explicitlyInvalidate {
                scoped?.invalidate()
                scoped?.invalidate()
                XCTAssertFalse(scoped?.validateCurrent() == true)
                XCTAssertEqual(owned.invalidationCount, 1)
            }
            scoped = nil

            XCTAssertNil(scopedReference)
            XCTAssertEqual(owned.invalidationCount, 1)
            XCTAssertEqual(catalog.orderedAccounts.count, 1)
        }
    }

    func testFinalSelectionDistinguishesRemovedAndUnavailableAccountsAfterClaim() async throws {
#if os(macOS)
        let modes = [false, true]
#else
        let modes = [false]
#endif
        for (native, knownButUnavailable) in modes.flatMap({ mode in [false, true].map { (mode, $0) } }) {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 601, provider: .ethereum,
                revisions: popupRevisions(ethereum: 1, solana: 0)
            ), in: store)
            let account = popupTestAccount()
            var access = WalletReviewCatalog(account: account)
            let network = popupTransactionNetwork()
            var executions = 0
            let processor = CompactPopupAccessProcessor(execute: { request, _, _, permit in
                executions += 1
                return approvedFailureForTesting(.internalError, permit: permit)
            }) { _, _ in
                .approval(.selectAccount(.init(
                    coinType: .ethereum, selectedAccounts: [],
                    initiallyConnectedProviders: [], network: network
                )))
            }
            await store.observeNextClaim { _ in
                access = WalletReviewCatalog(
                    identity: access.identity, orderedAccounts: [],
                    knownAccounts: knownButUnavailable ? access.knownAccounts : []
                )
            }

            if native {
#if os(macOS)
                let decision = DappApprovalDecision.accountSelection(.init(
                    accounts: [.init(walletID: "wallet", account: account)],
                    ethereumChainID: network.chainIdHexString
                ))
                let authorization = try await store.prepareNativeApproval(handle: snapshot.handle, decision: decision)
                let finalizer = NativeApprovalFinalizer(
                    store: store,
                    executionEnvironment: .init(
                        requestProcessor: processor
                    ),
                    refreshWalletCatalog: { access },
                    networkResolver: { _ in
                        .resolved(ResolvedEthereumNetwork(network: network, source: .custom))
                    }
                )
                let result = await finalizer.attempt(consent: authorization)
                let error = await store.completedErrorCode(handle: snapshot.handle)
                let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
                XCTAssertEqual(result, knownButUnavailable ? .reviewRequired : .responseReady)
                XCTAssertEqual(error, knownButUnavailable ? nil : ProviderResponseError.internalErrorCode)
                XCTAssertFalse(committed)
                let events = await store.events()
                XCTAssertEqual(events, ["nativeClaim", knownButUnavailable ? "returnToReview" : "complete"])
#endif
            } else {
                let controller = PopupRequestSessions(
                    store: store,
                    walletEnvironment: popupWalletEnvironment(reviewCatalog: { access }),
                    loadsTransactionContext: false,
                    selectionNetworkResolver: { _ in network },
                    approvalNetworkResolver: { _ in .resolved(ResolvedEthereumNetwork(network: network, source: .custom)) },
                    executionEnvironment: .init(
                        requestProcessor: processor
                    )
                )
                let token = try await materializeToken(controller: controller, snapshot: snapshot)
                let command = try popupCommand(
                    subject: "approveRequest", id: snapshot.handle.id,
                    requestToken: snapshot.handle.requestToken, reviewToken: token,
                    payload: [
                        "selectedAccounts": [["walletId": "wallet", "address": account.address,
                                              "coin": "ethereum", "derivationPath": account.derivationPath]],
                        "chainId": network.chainIdHexString,

                    ]
                )
                let response = await controller.dispatchJSON(request: command, profileIdentifier: nil)
                let error = await store.completedErrorCode(handle: snapshot.handle)
                let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
                let events = await store.events()
                XCTAssertEqual(response["status"] as? String, "ok")
                XCTAssertEqual(error, knownButUnavailable ? nil : ProviderResponseError.internalErrorCode)
                XCTAssertFalse(committed)
                XCTAssertEqual(events, ["claim", knownButUnavailable ? "returnToReview" : "complete"])
                if knownButUnavailable {
                    XCTAssertEqual(response["state"] as? String, "error")
                    XCTAssertEqual(response["actions"] as? [String], ["retry", "reject"])
                } else {
                    let retried = try await retryApproval(controller: controller, snapshot: snapshot)
                    XCTAssertEqual(retried["state"] as? String, "missing")
                }

            }
            XCTAssertEqual(executions, 0)
        }
    }

    func testSigningValidationRollbackDoesNotAcquireWalletLease() async throws {
        let store = try makeStore()
        let setup = try await makeExecutionSetup(store: store, id: 602)
        var acquisitions = 0
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in .rollback }) { _ in
                    .immediate(.failure(.internalError))
                }
            )
        )
        let result = await execute(executor, setup: setup, signing: .unlocked(makeWalletSigningSessionForTesting(
                authorization: walletSigningAuthorizationForTesting(
                    approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                    deadline: setup.claim.executionDeadline
                ),
                acquireCommitLease: { acquisitions += 1; return WalletExecutionLease(release: {}) }
            )))
        XCTAssertEqual(result, .abandoned)
        XCTAssertEqual(acquisitions, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])
    }

    func testSessionUsesFourDisposablePhasesAndOneReviewToken() throws {
        let session = try makeSession()
        let initialToken = session.reviewToken

        let token = try XCTUnwrap(session.beginApproval())
        guard case .working = session.presentation else { return XCTFail("Expected claiming presentation") }
        XCTAssertNotEqual(token, initialToken)

        XCTAssertFalse(session.hasActiveClaim)
        XCTAssertFalse(session.beginAuthentication(token: token))
        XCTAssertTrue(session.acceptClaim(token: token))
        XCTAssertTrue(session.hasActiveClaim)
        XCTAssertTrue(session.beginAuthentication(token: token))
        guard case .authenticating = session.presentation else { return XCTFail("Expected authentication presentation") }
        XCTAssertTrue(session.finishAuthentication(token: token))
        guard case .working = session.presentation else { return XCTFail("Expected working presentation") }
        XCTAssertTrue(session.returnToReview(token: token))
        guard case .review(let review) = session.presentation else { return XCTFail("Expected review presentation") }
        XCTAssertEqual(review.reviewToken, session.reviewToken)
        XCTAssertFalse(session.hasActiveClaim)

        session.fail("Unavailable")
        guard case .error(let message) = session.presentation else { return XCTFail("Expected error presentation") }
        XCTAssertEqual(message, "Unavailable")
    }

    func testStaleReviewTokenCannotMutateSession() throws {
        let session = try makeSession()
        let token = try XCTUnwrap(session.beginApproval())
        let stale = UUID()

        XCTAssertFalse(session.acceptClaim(token: stale))
        XCTAssertTrue(session.acceptClaim(token: token))
        XCTAssertFalse(session.beginAuthentication(token: stale))
        session.fail("stale", token: stale)
        guard case .working = session.presentation else { return XCTFail("Stale actions changed the presentation") }
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
    }

    func testSessionPreservesFeedbackAcrossAuthentication() throws {
        let session = try makeSession()
        session.setFeedback("Choose an account")
        XCTAssertEqual(session.errorText, "Choose an account")
        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertNil(session.errorText)
        XCTAssertTrue(session.acceptClaim(token: token))
        session.setFeedback("Try again")
        XCTAssertTrue(session.beginAuthentication(token: token))
        XCTAssertEqual(session.errorText, "Try again")
        XCTAssertTrue(session.finishAuthentication(token: token))
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertEqual(session.errorText, "Try again")
        XCTAssertFalse(session.hasActiveClaim)
        XCTAssertNotEqual(session.reviewToken, token)
        XCTAssertFalse(session.returnToReview(token: token))
    }

    func testSessionCanReturnToReviewFromUnclaimedAndFailedAttempts() throws {
        let session = try makeSession()
        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertTrue(session.returnToReview(token: token))
        guard case .review = session.presentation else { return XCTFail("Expected review after abandoning claim") }
        let freshToken = session.reviewToken
        XCTAssertNotEqual(freshToken, token)
        session.fail("Unavailable", token: token)
        guard case .review = session.presentation else { return XCTFail("Stale failure replaced the review") }
        XCTAssertFalse(session.returnToReview(token: token))
        session.fail("Unavailable", token: freshToken)
        XCTAssertTrue(session.returnToReview(token: freshToken))
        XCTAssertEqual(session.errorText, "Unavailable")
        XCTAssertFalse(session.hasActiveClaim)
        XCTAssertNotEqual(session.reviewToken, freshToken)
    }

    func testMobileDeadlineRollsBackAtEveryExactPrecommitBoundary() async throws {
        enum Boundary: CaseIterable { case postValidation, responseCompletion, broadcastCheckpoint }
        for (index, boundary) in Boundary.allCases.enumerated() {
            let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
            let store = try makeStore(clock: { clock.now })
            let setup = try await makeExecutionSetup(store: store, id: 450 + index)
            let deadline = setup.claim.executionDeadline
            if boundary == .responseCompletion { await store.setPermitCompletionHook { clock.now = deadline } }
            if boundary == .broadcastCheckpoint { await store.setBroadcastCheckpointHook { clock.now = deadline } }
            let processor = CompactPopupProcessor(execute: { _, _, signer, permit in
                boundary == .broadcastCheckpoint ? await popupPreparedBroadcast(permit: permit, signer: signer)
                    : approvedFailureForTesting(.internalError, permit: permit)
            }) { _ in .immediate(.failure(.internalError)) }
            let executor = DurableApprovalExecutor(
                store: store,
                environment: .init(
                    requestProcessor: processor,
                    broadcastSender: PopupBroadcastSender { _, _ in
                        XCTFail("Expired broadcast must not be sent")
                        return .failure(.transport)
                    },
                    clock: { clock.now }
                )
            )
            let result = await execute(executor, setup: setup, signing: .unlocked(makeWalletSigningSessionForTesting(
                    authorization: walletSigningAuthorizationForTesting(
                        approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle, deadline: deadline
                    ),
                    acquireCommitLease: {
                        if boundary == .postValidation { clock.now = deadline }
                        return WalletExecutionLease(release: {})
                    }, clock: { clock.now }
                )))
            XCTAssertEqual(result, boundary == .responseCompletion ? .ownershipLost : .abandoned)
            let events = await store.events()
            XCTAssertEqual(events, boundary == .responseCompletion ? ["claim"] : ["claim", "abandon"])
            let recovered = try await store.snapshot(handle: setup.snapshot.handle)
            XCTAssertEqual(recovered.phase, .queued)
            let response = await store.response(handle: setup.snapshot.handle)
            XCTAssertNil(response)
            let checkpointed = await store.checkpointApprovalWasCommitted(handle: setup.snapshot.handle)
            XCTAssertFalse(checkpointed)
        }
    }

    func testBroadcastStillSendsWhenDeadlineExpiresAfterCheckpoint() async throws {
        let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = try makeStore(clock: { clock.now })
        let setup = try await makeExecutionSetup(store: store, id: 455)
        let deadline = setup.claim.executionDeadline
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                    await popupPreparedBroadcast(permit: permit, signer: signer)
                }) { _ in .immediate(.failure(.internalError)) },
                broadcastSender: PopupBroadcastSender { _, _ in
                    await store.record("send")
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))
                },
                clock: { clock.now }
            )
        )
        let result = await execute(executor, setup: setup, signing: .unlocked(makeWalletSigningSessionForTesting(
                authorization: walletSigningAuthorizationForTesting(
                    approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle, deadline: deadline
                ),
                acquireCommitLease: { WalletExecutionLease { clock.now = deadline } },
                clock: { clock.now }
            )))
        XCTAssertEqual(result, .persisted)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "checkpoint", "send", "complete"])
        let code = await store.completedErrorCode(handle: setup.snapshot.handle)
        XCTAssertEqual(code, 4001)
    }

    func testExecutionLeaseCoversDurableCommitAndEndsBeforeBroadcast() async throws {
        for broadcasts in [false, true] {
            let store = try makeStore()
            let setup = try await makeExecutionSetup(store: store, id: broadcasts ? 454 : 453)
            let state = CompactExecutionLeaseState()
            await store.setPermitCompletionHook { state.observeDurableCommit() }
            await store.setBroadcastCheckpointHook { state.observeDurableCommit() }
            let executor = DurableApprovalExecutor(
                store: store,
                environment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                        broadcasts ? await popupPreparedBroadcast(permit: permit, signer: signer)
                            : approvedFailureForTesting(.internalError, permit: permit)
                    }) { _ in .immediate(.failure(.internalError)) },
                    broadcastSender: PopupBroadcastSender { _, _ in
                        state.observeBroadcast()
                        return .failure(.rpc(.serverError(4001, Strings.canceled)))
                    }
                )
            )
            let result = await execute(executor, setup: setup, signing: .unlocked(makeWalletSigningSessionForTesting(
                    authorization: walletSigningAuthorizationForTesting(
                        approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                        deadline: setup.claim.executionDeadline
                    ),
                    acquireCommitLease: { WalletExecutionLease { state.release() } }
                )))
            XCTAssertEqual(result, .persisted)
            XCTAssertTrue(state.wasHeldAtDurableCommit)
            XCTAssertTrue(state.isReleased)
            if broadcasts { XCTAssertTrue(state.wasReleasedBeforeBroadcast) }
        }
    }

    func testCatalogResolutionDeadlineReleasesClaimAndDiscardsLateApproval() async throws {
        let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = try makeStore(clock: { clock.now })
        let setup = try await makeExecutionSetup(store: store, id: 610, signing: false)
        let gate = makeGate()
        let started = expectation(description: "catalog refresh started")
        let finished = expectation(description: "catalog deadline returned before refresh")
        let late = expectation(description: "late catalog refresh discarded")
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                    XCTFail("A catalog result arriving after the deadline must not execute")
                    return .rollback
                }),
                clock: { setup.claim.executionDeadline.addingTimeInterval(-0.01) }
            )
        )
        let task = Task {
            let result = await executor.execute(
                claim: setup.claim,
                prepare: { _ in .ready(consent: setup.consent, signing: .none) },
                resolve: { _ in
                    started.fulfill()
                    await gate.wait()
                    XCTAssertTrue(Task.isCancelled)
                    late.fulfill()
                    return .approved(setup.approval)
                }
            )
            XCTAssertEqual(result, .abandoned)
            finished.fulfill()
        }
        await fulfillment(of: [started, finished], timeout: 1)
        let beforeLateResult = await store.events()
        XCTAssertEqual(beforeLateResult, ["claim", "abandon"])
        await gate.open()
        await task.value
        await fulfillment(of: [late], timeout: 1)
        let afterLateResult = await store.events()
        XCTAssertEqual(afterLateResult, beforeLateResult)
    }

    func testOperationTimeoutReturnsBeforeUncooperativeWorkAndNeverSendsLateBroadcast() async throws {
        let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = try makeStore(clock: { clock.now })
        let setup = try await makeExecutionSetup(store: store, id: 456)
        let gate = makeGate()
        let finished = expectation(description: "timed out before gate opened")
        let late = expectation(description: "late operation returned")
        var leases = 0
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                    let prepared = await popupPreparedBroadcast(permit: permit, signer: signer)
                    guard case .broadcast = prepared else {
                        XCTFail("Expected a signed broadcast before the operation stalls")
                        return .rollback
                    }
                    await gate.wait()
                    XCTAssertTrue(Task.isCancelled)
                    late.fulfill()
                    return prepared
                }) { _ in .immediate(.failure(.internalError)) },
                broadcastSender: PopupBroadcastSender { _, _ in
                    XCTFail("Late prepared broadcast must not send")
                    return .failure(.transport)
                },
                clock: { setup.claim.executionDeadline.addingTimeInterval(-0.1) }
            )
        )
        let task = Task { @MainActor in
            let result = await execute(executor, setup: setup, signing: .unlocked(makeWalletSigningSessionForTesting(
                    authorization: walletSigningAuthorizationForTesting(
                        approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                        deadline: setup.claim.executionDeadline
                    ),
                    acquireCommitLease: { leases += 1; return WalletExecutionLease(release: {}) },
                    clock: { setup.claim.executionDeadline.addingTimeInterval(-0.1) }
                )))
            XCTAssertEqual(result, .abandoned)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(leases, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])
        await gate.open()
        await task.value
        await fulfillment(of: [late], timeout: 1)
        let after = await store.events()
        XCTAssertEqual(after, events)
    }

    func testExpiredOperationDeadlineNeverStartsWorkOrAcquiresLease() async throws {
        for kind in ["ordinary", "mobile", "native"] {
            for offset in [0.0, 1.0] {
                let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_700_000_000))
                let store = try makeStore(clock: { clock.now })
                let setup = try await makeExecutionSetup(store: store, id: 457, native: kind == "native", signing: kind != "ordinary")
                let executor = DurableApprovalExecutor(
                    store: store,
                    environment: .init(
                        requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                            XCTFail("Expired operation must not start")
                            return .rollback
                        }) { _ in .immediate(.failure(.internalError)) },
                        clock: { setup.claim.executionDeadline.addingTimeInterval(offset) }
                    )
                )
                let result: DurableApprovalExecutor.Result
                if kind == "ordinary" {
                    result = await execute(executor, setup: setup, signing: .none)
                } else if kind == "native" {
                    result = await execute(executor, setup: setup, signing: .source { _ in
                        XCTFail("Expired operation must not create a signer")
                        return TestWalletSigner()
                    })
                } else {
                    let session = makeWalletSigningSessionForTesting(
                        authorization: walletSigningAuthorizationForTesting(
                            approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                            deadline: setup.claim.executionDeadline
                        ),
                        acquireCommitLease: { XCTFail("Expired operation must not acquire a lease"); return nil },
                        clock: { setup.claim.executionDeadline.addingTimeInterval(offset) }
                    )
                    defer { session.invalidate() }
                    result = await execute(executor, setup: setup, signing: .unlocked(session))
                }
                XCTAssertEqual(result, .abandoned)
                let events = await store.events()
                XCTAssertEqual(events, [kind == "native" ? "nativeClaim" : "claim", "abandon"])
            }
        }
    }

    func testNativeCallerCancellationAfterCheckpointPersistsTheBroadcastResult() async throws {
        let store = try makeStore()
        let setup = try await makeExecutionSetup(store: store, id: 607, native: true)
        let gate = makeGate()
        let started = expectation(description: "broadcast started after checkpoint")
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                    await popupPreparedBroadcast(permit: permit, signer: signer)
                }) { _ in .immediate(.failure(.internalError)) },
                broadcastSender: PopupBroadcastSender { _, _ in
                    await store.record("send")
                    started.fulfill()
                    await gate.wait()
                    XCTAssertFalse(Task.isCancelled)
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))
                }
            )
        )
        let task = Task { @MainActor in
            await execute(executor, setup: setup, signing: .source { makeWalletSignerForTesting($0) })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.open()
        let taskResult = await task.value
        XCTAssertEqual(taskResult, .persisted)
        let events = await store.events()
        XCTAssertEqual(events, ["nativeClaim", "checkpoint", "send", "complete"])
        let response = await store.response(handle: setup.snapshot.handle)
        XCTAssertEqual(response?["approvalCommitted"] as? Bool, true)
        XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, 4001)
    }

    func testNativeCancellationAtCommittedCheckpointStillStartsBroadcastOnce() async throws {
        let store = try makeStore()
        let setup = try await makeExecutionSetup(store: store, id: 608, native: true)
        await store.setBroadcastCheckpointCommittedHook { withUnsafeCurrentTask { $0?.cancel() } }
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                    await popupPreparedBroadcast(permit: permit, signer: signer)
                }) { _ in .immediate(.failure(.internalError)) },
                broadcastSender: PopupBroadcastSender { _, _ in
                    XCTAssertFalse(Task.isCancelled)
                    await store.record("send")
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))
                }
            )
        )
        let task = Task { @MainActor in
            await execute(executor, setup: setup, signing: .source { makeWalletSignerForTesting($0) })
        }
        let taskResult = await task.value
        XCTAssertEqual(taskResult, .persisted)
        XCTAssertTrue(task.isCancelled)
        let events = await store.events()
        XCTAssertEqual(events, ["nativeClaim", "checkpoint", "send", "complete"])
        let response = await store.response(handle: setup.snapshot.handle)
        XCTAssertEqual(response?["approvalCommitted"] as? Bool, true)
    }

    func testCopiedClaimCannotPrepareTwiceAcrossExecutors() async throws {
        let store = try makeStore()
        let setup = try await makeExecutionSetup(store: store, id: 609)
        let gate = makeGate()
        let started = expectation(description: "original preparation started")
        let access = BorrowedWalletSignerForTesting()
        let signer = WalletSigningSession(
            access,
            authorization: walletSigningAuthorizationForTesting(
                approvedAccount: popupTestAccountDescriptor(), handle: setup.claim.handle,
                deadline: setup.claim.executionDeadline
            ),
            isCurrent: { true },
            acquireCommitLease: { WalletExecutionLease(release: {}) }
        )
        var preparations = 0
        var executions = 0
        let processor = CompactPopupProcessor(execute: { _, _, _, permit in
            executions += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _ in .immediate(.failure(.internalError)) }
        let original = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: processor
            )
        )
        let duplicate = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: processor
            )
        )
        let task = Task { @MainActor in
            await original.execute(claim: setup.claim, prepare: { context in
                preparations += 1
                XCTAssertEqual(context.handle, setup.claim.handle)
                XCTAssertEqual(context.executionDeadline, setup.claim.executionDeadline)
                started.fulfill()
                await gate.wait()
                return .ready(consent: setup.consent, signing: .unlocked(signer))
            }, resolve: { _ in .approved(setup.approval) })
        }
        await fulfillment(of: [started], timeout: 1)
        let copiedClaim = setup.claim
        let duplicateResult = await duplicate.execute(claim: copiedClaim, prepare: { _ in
            XCTFail("A copied claim must not start another authentication or preparation")
            return .ready(consent: setup.consent, signing: .unlocked(signer))
        }, resolve: { _ in
            XCTFail("A copied claim must not resolve the original approval")
            return .approved(setup.approval)
        })
        XCTAssertEqual(duplicateResult, .ownershipLost)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(access.invalidationCount, 0)
        XCTAssertTrue(signer.validateCurrent())
        let before = await store.events()
        XCTAssertEqual(before, ["claim"])
        let lock = CrossProcessFileLock(fileURL: await store.operationLockURL(handle: setup.claim.handle))
        XCTAssertFalse(try lock.tryAcquireExisting())
        lock.release()

        await gate.open()
        let result = await task.value
        XCTAssertEqual(result, .persisted)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(access.invalidationCount, 1)
        let after = await store.events()
        XCTAssertEqual(after, ["claim", "complete"])
    }

    func testDuplicateExecutionCannotReleaseTheOriginalPermit() async throws {
        for signing in [false, true] {
            let store = try makeStore()
            let setup = try await makeExecutionSetup(store: store, id: signing ? 604 : 603, signing: signing)
            let gate = makeGate()
            let started = expectation(description: "original execution started")
            var executions = 0
            let executor = DurableApprovalExecutor(
                store: store,
                environment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, permit in
                        executions += 1
                        started.fulfill()
                        await gate.wait()
                        return approvedFailureForTesting(.userRejected, permit: permit)
                    }) { _ in .immediate(.failure(.internalError)) }
                )
            )
            let session = makeWalletSigningSessionForTesting(
                authorization: walletSigningAuthorizationForTesting(
                    approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                    deadline: setup.claim.executionDeadline
                )
            )
            defer { session.invalidate() }
            let task = Task { @MainActor in
                signing ? await execute(executor, setup: setup, signing: .unlocked(session))
                    : await execute(executor, setup: setup, signing: .none)
            }
            await fulfillment(of: [started], timeout: 1)
            let duplicate = signing
                ? await execute(executor, setup: setup, signing: .unlocked(session))
                : await execute(executor, setup: setup, signing: .none)
            XCTAssertEqual(duplicate, .ownershipLost)
            if signing { XCTAssertTrue(session.validateCurrent()) }
            let lock = CrossProcessFileLock(fileURL: await store.operationLockURL(handle: setup.snapshot.handle))
            XCTAssertFalse(try lock.tryAcquireExisting())
            lock.release()
            guard case .found(let held) = await store.load(handle: setup.snapshot.handle) else {
                await gate.open(); _ = await task.value
                return XCTFail("Expected original execution")
            }
            XCTAssertEqual(held.phase, .approving)
            await gate.open()
            let taskResult = await task.value
        XCTAssertEqual(taskResult, .persisted)
            XCTAssertEqual(executions, 1)
        }
    }

    func testExecutorReleasesUnapprovedLeaseWhenAuthorizationAndAbandonFail() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 606, provider: .ethereum, method: "addEthereumChain"), in: store)
        await store.failNextAuthorization()
        await store.forceNextAbandonResult(.retryablePersistenceFailure)
        let controller = popupController(store: store)
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        _ = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        ), profileIdentifier: nil)
        let lockURL = await store.operationLockURL(handle: snapshot.handle)
        if FileManager.default.fileExists(atPath: lockURL.path) {
            let lock = CrossProcessFileLock(fileURL: lockURL)
            XCTAssertTrue(try lock.tryAcquireExisting())
            lock.release()
        }
        guard case .found(let recovered) = await store.load(handle: snapshot.handle) else {
            return XCTFail("Expected recoverable claim")
        }
        XCTAssertEqual(recovered.phase, .queued)
    }

    func testCallerCancellationDoesNotAbortStartedDurableOperation() async throws {
        for cancelDuringLease in [false, true] {
            let store = try makeStore()
            let setup = try await makeExecutionSetup(store: store, id: 458)
            let gate = makeGate()
            let started = expectation(description: "cancellation boundary reached")
            let executor = DurableApprovalExecutor(
                store: store,
                environment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, permit in
                        if !cancelDuringLease { started.fulfill(); await gate.wait() }
                        XCTAssertFalse(Task.isCancelled)
                        return approvedFailureForTesting(.userRejected, permit: permit)
                    }) { _ in .immediate(.failure(.internalError)) }
                )
            )
            let session = makeWalletSigningSessionForTesting(
                authorization: walletSigningAuthorizationForTesting(
                    approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                    deadline: setup.claim.executionDeadline
                ),
                acquireCommitLease: {
                    if cancelDuringLease { started.fulfill(); await gate.wait() }
                    return WalletExecutionLease(release: {})
                }
            )
            let task = Task { @MainActor in
                await execute(executor, setup: setup, signing: .unlocked(session))
            }
            await fulfillment(of: [started], timeout: 1)
            task.cancel()
            await gate.open()
            let taskResult = await task.value
        XCTAssertEqual(taskResult, .persisted)
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "complete"])
        }
    }

    func testZeroBroadcastTimeoutPersistsRecoveryWithoutLateRedispatch() async throws {
        let store = try makeStore()
        let setup = try await makeExecutionSetup(store: store, id: 459)
        let gate = makeGate()
        let finished = expectation(description: "zero timeout recovery")
        var sendStarted = false
        var sendFinished = false
        let executor = DurableApprovalExecutor(
            store: store,
            environment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                    await popupPreparedBroadcast(permit: permit, signer: signer)
                }) { _ in .immediate(.failure(.internalError)) },
                broadcastSender: PopupBroadcastSender { _, _ in
                    sendStarted = true
                    await store.record("send")
                    await gate.wait()
                    sendFinished = true
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))
                },
                broadcastTimeoutNanoseconds: 0
            )
        )
        let task = Task { @MainActor in
            let result = await execute(executor, setup: setup, signing: .unlocked(makeWalletSigningSessionForTesting(authorization: walletSigningAuthorizationForTesting(
                    approvedAccount: popupTestAccountDescriptor(), handle: setup.snapshot.handle,
                    deadline: setup.claim.executionDeadline
                ))))
            XCTAssertEqual(result, .persisted)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        let before = await store.completedErrorCode(handle: setup.snapshot.handle)
        XCTAssertEqual(before, ProviderResponseError.internalErrorCode)
        let startedAtCompletion = sendStarted
        await gate.open()
        await task.value
        if sendStarted { try await waitForCondition { sendFinished } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(sendStarted, startedAtCompletion)
        let events = await store.events()
        XCTAssertLessThanOrEqual(events.filter { $0 == "send" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "complete" }.count, 1)
        let after = await store.completedErrorCode(handle: setup.snapshot.handle)
        XCTAssertEqual(after, before)
    }

    func testRecoveryWorkerCommandsUseExactNativeEnvelopes() throws {
        func decode(_ values: [String: Any]) throws -> InternalSafariRequest {
            try JSONDecoder().decode(
                InternalSafariRequest.self,
                from: JSONSerialization.data(withJSONObject: values)
            )
        }
        let listing: [String: Any] = [
            "id": 400,
            "subject": "getRecoveryRequests",
            "workflowVersion": ExtensionBridge.workflowVersion,
        ]
        guard case .worker(.getRecoveryRequests) =
            try decode(listing).command else {
            return XCTFail("Expected a worker-only discovery command")
        }
        let token = UUID().uuidString.lowercased()
        let response: [String: Any] = [
            "id": 401,
            "subject": "pollResponse",
            "workflowVersion": ExtensionBridge.workflowVersion,
            "configurationKey": "https://wallet.example",
            "requestToken": token,
            "maintenance": "quiet",
        ]
        guard case .worker(.pollResponse(let identity)) =
            try decode(response).command else {
            return XCTFail("Expected a worker-only response command")
        }
        XCTAssertEqual(identity.response.token.rawValue, token)
        XCTAssertEqual(identity.response.configurationKey, "https://wallet.example")
        XCTAssertEqual(identity.maintenance, .quiet)
        for extra in ["profileIdentifier", "privateBrowsing", "host", "payload", "revisions", "executionDeadline"] {
            for original in [listing, response] {
                var malformed = original
                malformed[extra] = "untrusted"
                XCTAssertThrowsError(try decode(malformed))
            }
        }
        for field in ["configurationKey", "requestToken", "maintenance"] {
            var malformed = response
            malformed.removeValue(forKey: field)
            XCTAssertThrowsError(try decode(malformed))
        }
    }

    func testTransactionSessionCompletesSynchronousPreflightOnce() async throws {
        let session = await makeTransactionApprovalSession { transaction, _ in
            let source = PopupPreflightSource()
            source.resolve(.safe(transaction, popupTransactionEstimate()))
            source.resolve(.safe(transaction, popupTransactionEstimate()))
            return try await source.value(cancellation: nil)
        }
        let token = try XCTUnwrap(session.beginApproval())
        let result = await session.finishAuthentication(token: token, succeeded: true)
        guard case .approved(let transaction) = result else {
            return XCTFail("Expected approved transaction")
        }
        XCTAssertEqual(transaction.id, session.snapshot.transaction.id)
        XCTAssertEqual(session.snapshot.phase, .finished)
        XCTAssertNil(session.activeAlert)
    }

    func testTransactionSessionRejectsDuplicatesAndFreezesPreparationDuringAuthentication()
        async throws {
        var preparationUpdate: ((Transaction) -> Void)?
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        var preflightTransaction: Transaction?
        let session = await makeTransactionApprovalSession(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                preparationUpdate = source.update
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { transaction, _ in
                let source = PopupPreflightSource()
                preflightTransaction = transaction
                preflightCompletion = source.resolve
                return try await source.value(cancellation: nil)
            }
        )
        let reviewedTransaction = session.snapshot.transaction
        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertEqual(session.snapshot.phase, .authenticating)
        var lateTransaction = reviewedTransaction
        lateTransaction.interpretation = "Unreviewed preparation update"
        preparationUpdate?(lateTransaction)
        XCTAssertNil(session.beginApproval())
        XCTAssertEqual(session.snapshot.transaction.interpretation, reviewedTransaction.interpretation)
        XCTAssertNil(preflightCompletion)
        let approvalTask = Task { @MainActor in
            await session.finishAuthentication(token: token, succeeded: true)
        }
        try await waitForCondition { preflightCompletion != nil }
        XCTAssertNil(session.beginApproval())
        let duplicate = await session.finishAuthentication(token: token, succeeded: true)
        guard case .invalidated = duplicate else { return XCTFail("Expected duplicate rejection") }
        XCTAssertEqual(session.snapshot.phase, .preflighting)
        XCTAssertEqual(preflightTransaction?.interpretation, reviewedTransaction.interpretation)
        preflightCompletion?(.safe(reviewedTransaction, popupTransactionEstimate()))
        guard case .approved = await approvalTask.value else { return XCTFail("Expected approval") }
    }

    func testTransactionSessionInvalidationWinsAlreadyResumedPreflight() async throws {
        var session: PopupTransactionSession!
        session = await makeTransactionApprovalSession { transaction, _ in
            let source = PopupPreflightSource()
            source.resolve(.safe(transaction, popupTransactionEstimate()))
            session.invalidate()
            return try await source.value(cancellation: nil)
        }
        let token = try XCTUnwrap(session.beginApproval())
        let result = await session.finishAuthentication(token: token, succeeded: true)
        guard case .invalidated = result else {
            return XCTFail("Invalidation must fence a preflight result that has already resumed")
        }
        XCTAssertNil(session.beginApproval())
    }

    func testTransactionSessionAuthenticationRefusalAllowsFreshApproval() async throws {
        var preflightCount = 0
        let session = await makeTransactionApprovalSession { transaction, _ in
            let source = PopupPreflightSource()
            preflightCount += 1
            source.resolve(.safe(transaction, popupTransactionEstimate()))
            return try await source.value(cancellation: nil)
        }
        let firstToken = try XCTUnwrap(session.beginApproval())
        let refused = await session.finishAuthentication(token: firstToken, succeeded: false)
        guard case .reviewRequired = refused else { return XCTFail("Expected another review") }
        XCTAssertEqual(preflightCount, 0)
        XCTAssertEqual(session.snapshot.phase, .ready)
        XCTAssertTrue(session.snapshot.canApprove)
        let nextToken = try XCTUnwrap(session.beginApproval())
        let retried = await session.finishAuthentication(token: nextToken, succeeded: true)
        guard case .approved = retried else { return XCTFail("Expected approval") }
        XCTAssertEqual(preflightCount, 1)
    }

    func testTransactionSessionPreflightAlertsRemainPresentable() async throws {
        let cases: [(
            TransactionApprovalAlertIntent.Kind,
            (Transaction, GasService.Estimate) -> TransactionFeePreflightResult
        )] = [
            (.feesUpdated, { .walletManagedUpdated($0, $1) }),
            (.unsafeFees, { .userControlledUnsafe($0, $1) }),
            (.unavailableFees, { .unavailable($0, $1) }),
        ]
        for (kind, makeResult) in cases {
            let session = await makeTransactionApprovalSession { transaction, _ in
                let source = PopupPreflightSource()
                source.resolve(makeResult(transaction, popupTransactionEstimate()))
                source.resolve(.safe(transaction, popupTransactionEstimate()))
                return try await source.value(cancellation: nil)
            }
            let token = try XCTUnwrap(session.beginApproval())
            let result = await session.finishAuthentication(token: token, succeeded: true)
            guard case .reviewRequired = result else { return XCTFail("Expected review") }
            XCTAssertEqual(session.activeAlert?.kind, kind)
            XCTAssertFalse(session.activeAlert?.presentation.actions.isEmpty ?? true)
            XCTAssertNotEqual(session.snapshot.phase, .finished)
        }
    }

    func testTransactionSessionInvalidationRejectsLateAuthentication() async throws {
        var preflightCount = 0
        let session = await makeTransactionApprovalSession { _, _ in
            let source = PopupPreflightSource()
            preflightCount += 1
            return try await source.value(cancellation: nil)
        }
        let token = try XCTUnwrap(session.beginApproval())
        session.invalidate()
        session.invalidate()
        let result = await session.finishAuthentication(token: token, succeeded: true)
        guard case .invalidated = result else { return XCTFail("Expected invalidation") }
        XCTAssertNil(session.beginApproval())
        XCTAssertEqual(preflightCount, 0)
        XCTAssertEqual(session.snapshot.phase, .finished)
    }

    func testTransactionSessionInvalidationSettlesPreflightAndIgnoresLateResults()
        async throws {
        let cancellation = PopupCancellationRecorder()
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        let session = await makeTransactionApprovalSession { _, _ in
            let source = PopupPreflightSource()
            preflightCompletion = source.resolve
            return try await source.value(cancellation: cancellation)
        }
        let transaction = session.snapshot.transaction
        let token = try XCTUnwrap(session.beginApproval())
        var approvalCompleted = false
        let approvalTask = Task { @MainActor in
            let result = await session.finishAuthentication(token: token, succeeded: true)
            approvalCompleted = true
            return result
        }
        try await waitForCondition { preflightCompletion != nil }
        session.invalidate()
        session.invalidate()
        try await waitForCondition { approvalCompleted }
        guard case .invalidated = await approvalTask.value else { return XCTFail("Expected invalidation") }
        XCTAssertTrue(cancellation.isCancelled)
        preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
        preflightCompletion?(.unavailable(transaction, popupTransactionEstimate()))
        XCTAssertEqual(session.snapshot.phase, .finished)
        XCTAssertNil(session.activeAlert)
        XCTAssertFalse(session.snapshot.canApprove)
    }

    private func settleTransactionPreparation(_ session: PopupTransactionSession) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while session.snapshot.phase == .preparing, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    private func makeTransactionApprovalSession(
        transaction: Transaction = popupReadyTransaction(),
        prepare: @escaping TransactionApprovalOperations.Prepare = { transaction, _, _ in
            let source = PopupPreparationSource()
            source.resolve(.success(transaction))
            return source.stream
        },
        preflight: @escaping TransactionApprovalOperations.Preflight
    ) async -> PopupTransactionSession {
        let session = PopupTransactionSession(
            action: SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: popupTransactionNetwork(),
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount()
            ),
            operations: TransactionApprovalOperations(
                prepare: prepare,
                preflight: preflight
            )
        )
        session.start()
        await settleTransactionPreparation(session)
        return session
    }

    func testCancelledTransactionSpeedLeavesFeeAndSelectionUnchanged() async throws {
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
            account: popupTestAccount()
        )
        var preparationCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { _, _, _ in
                let source = PopupPreparationSource()
                preparationCount += 1
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()

                return try await source.value(cancellation: nil)
            }
        )
        let session = PopupTransactionSession(
            action: action,
            operations: operations
        )
        session.start()
        let fee = session.snapshot.transaction.preparedFee
        let position = session.snapshot.gasSliderPosition
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
            session.snapshot.gasSliderPosition,
            position
        )
        XCTAssertEqual(preparationCount, 1)
    }

    func testCompletedPopupSpeedChangePublishesConsistentSelectionAndPreparesOnce() async throws {
        let transaction = Transaction(
            from: popupTestAccount().address,
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0", gas: "0x5208", value: "0x0", data: "0x",
            feeIntent: .eip1559(maxPriorityFeePerGas: 100, maxFeePerGas: 300),
            preparedFee: .eip1559(maxPriorityFeePerGas: 100, maxFeePerGas: 300),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        let estimate = GasService.Estimate(
            info: .init(recommendedPriorityFee: 100, highPriorityFee: 200),
            nextBaseFee: 100, currentBaseFee: 100,
            support: .eip1559, endpointChainID: 10
        )
        var preparationCount = 0
        let session = await makeTransactionApprovalSession(
            transaction: transaction,
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                preparationCount += 1
                source.estimate(estimate)
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()

                return try await source.value(cancellation: nil)
            }
        )
        let selectedPosition = 137.5
        var observedPositions = [Double]()
        session.onChange = { [weak session] in
            guard let session else { return }
            if session.snapshot.transaction.speedPriorityFeeSource == .slider {
                observedPositions.append(session.snapshot.gasSliderPosition)
            }
        }
        let payload = try JSONDecoder().decode(
            InternalSafariRequest.TransactionSpeedPayload.self,
            from: JSONSerialization.data(withJSONObject: [
                "interaction": "ended", "value": selectedPosition,
            ])
        )

        session.setSpeed(payload)
        await settleTransactionPreparation(session)

        XCTAssertEqual(preparationCount, 2)
        XCTAssertEqual(session.snapshot.phase, .ready)
        XCTAssertEqual(session.snapshot.transaction.speedPriorityFeeSource, .slider)
        XCTAssertFalse(observedPositions.isEmpty)
        XCTAssertTrue(observedPositions.allSatisfy { $0 == selectedPosition })
        XCTAssertEqual(session.snapshot.gasSliderPosition, selectedPosition)
    }

    func testPriorityFeeEditPreservesUntouchedFeeCapProvenance() async {
        for source in [TransactionFeeSource.automatic, .dapp] {
            let session = await makeFeeEditingSession(provenance: .init(
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

    func testFeeCapEditPreservesUntouchedPriorityFeeProvenance() async {
        for source in [TransactionFeeSource.automatic, .dapp] {
            let session = await makeFeeEditingSession(provenance: .init(
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

    func testCustomFeeEditReplacesSliderProvenanceForBothFields() async {
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
                let session = await makeFeeEditingSession(provenance: provenance)

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

    func testNonceOnlyEditPreservesFeeProvenance() async {
        for source in [TransactionFeeSource.automatic, .dapp, .slider] {
            let provenance = TransactionFeeProvenance(
                maxPriorityFeePerGas: source,
                maxFeePerGas: source
            )
            let session = await makeFeeEditingSession(provenance: provenance)

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

    func testNonceOnlyEditKeepsFailedTransactionUnapprovable() async {
        let transaction = Transaction(
            from: popupTestAccount().address,
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic
        )
        var preparationCount = 0
        let session = await makeTransactionApprovalSession(
            transaction: transaction,
            prepare: { _, _, _ in
                let source = PopupPreparationSource()
                preparationCount += 1
                source.resolve(.failure(.gasPriceUnavailable))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()
                XCTFail("An invalid fee must not reach preflight")
                return try await source.value(cancellation: nil)
            }
        )

        XCTAssertTrue(session.applyEdits(
            .custom(.init(
                nonce: "1",
                gasPriceGwei: "",
                maxPriorityFeePerGasGwei: nil,
                maxFeePerGasGwei: nil
            )),
            chain: popupTransactionNetwork()
        ))

        await settleTransactionPreparation(session)
        XCTAssertEqual(session.snapshot.transaction.decimalNonceString, "1")
        XCTAssertNil(session.snapshot.transaction.preparedFee)
        XCTAssertEqual(session.snapshot.phase, .failed)
        XCTAssertFalse(session.snapshot.canApprove)
        XCTAssertEqual(preparationCount, 2)
    }

    func testSuggestedEditRestoresNonceAndOwnershipOfUnchangedFee() async {
        var transaction = popupReadyTransaction()
        transaction.replacePreparedFee(
            .legacy(gasPrice: 10),
            provenance: .init(gasPrice: .manual)
        )
        let session = await makeTransactionApprovalSession(
            transaction: transaction,
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                source.estimate(popupTransactionEstimate())
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()

                return try await source.value(cancellation: nil)
            }
        )
        XCTAssertTrue(session.applyEdits(
            .custom(.init(
                nonce: "7",
                gasPriceGwei: "0.00000001",
                maxPriorityFeePerGasGwei: nil,
                maxFeePerGasGwei: nil
            )),
            chain: popupTransactionNetwork()
        ))
        XCTAssertEqual(session.snapshot.transaction.feeProvenance.gasPrice, .manual)

        await settleTransactionPreparation(session)
        XCTAssertTrue(session.applyEdits(.suggested, chain: popupTransactionNetwork()))
        await settleTransactionPreparation(session)

        XCTAssertEqual(session.snapshot.transaction.decimalNonceString, "0")
        XCTAssertEqual(session.snapshot.transaction.preparedFee, .legacy(gasPrice: 10))
        XCTAssertEqual(session.snapshot.transaction.feeProvenance.gasPrice, .automatic)
    }

    func testInvalidCustomFeeDoesNotApplyNonceAndNoOpDoesNotRestartPreparation() async {
        var preparationCount = 0
        let session = await makeTransactionApprovalSession(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                preparationCount += 1
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()

                return try await source.value(cancellation: nil)
            }
        )
        let original = session.snapshot.transaction

        XCTAssertFalse(session.applyEdits(
            .custom(.init(
                nonce: "1",
                gasPriceGwei: "invalid",
                maxPriorityFeePerGasGwei: nil,
                maxFeePerGasGwei: nil
            )),
            chain: popupTransactionNetwork()
        ))
        XCTAssertTrue(session.applyEdits(
            .custom(.init(
                nonce: original.editableFields.nonce,
                gasPriceGwei: original.editableFields.gasPriceGwei,
                maxPriorityFeePerGasGwei: nil,
                maxFeePerGasGwei: nil
            )),
            chain: popupTransactionNetwork()
        ))

        XCTAssertEqual(session.snapshot.transaction.id, original.id)
        XCTAssertEqual(session.snapshot.transaction.nonce, original.nonce)
        XCTAssertEqual(preparationCount, 1)
    }

    private func makeFeeEditingSession(
        provenance: TransactionFeeProvenance
    ) async -> PopupTransactionSession {
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
                account: popupTestAccount()
            ),
            operations: TransactionApprovalOperations(
                prepare: { transaction, _, _ in
                    let source = PopupPreparationSource()
                    source.resolve(.success(transaction))
                    return source.stream
                },
                preflight: { _, _ in
                    let source = PopupPreflightSource()

                    return try await source.value(cancellation: nil)
                }
            )
        )
        session.start()
        await settleTransactionPreparation(session)
        return session
    }

    private func makeSession() throws -> PopupRequestSession {
        let fixture = try ApprovedExecutionTestFixture()
        let snapshot = try fixture.enqueue(
            id: 42, name: "switchAccount", provider: .unknown,
            body: ["latestConfigurations": []]
        )
        return PopupRequestSession(intent: try reviewIntentForTesting(
            binding: XCTUnwrap(snapshot.requestBinding),
            action: .switchAccount(SelectAccountAction(
                coinType: nil,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: nil
            ))
        ), transactionApprovalOperations: unusedPopupTransactionOperations())
    }
}

@MainActor
extension PopupRequestSessionsTests {

    func testPendingResponseIsFIFO() async throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try makeStore(clock: { receivedAt })
        let first = try await enqueue(popupSnapshot(
            id: 1,
            createdAt: receivedAt,
            provider: .ethereum
        ), in: store)
        let second = try await enqueue(popupSnapshot(id: 2, createdAt: receivedAt, provider: .unknown), in: store)
        XCTAssertEqual(first.createdAt, second.createdAt)
        XCTAssertLessThan(first.sequence, second.sequence)
        let controller = popupController(store: store)
        let request = try popupCommand(subject: "getPendingRequests", id: 99)

        let response = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(response["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.compactMap { $0["id"] as? Int }, [1, 2])
        XCTAssertEqual(
            requests.compactMap { $0["configurationKey"] as? String },
            ["https://wallet.example", "https://wallet.example"]
        )
        XCTAssertEqual(
            requests.compactMap { $0["provider"] as? String },
            ["ethereum", "unknown"]
        )
        XCTAssertTrue(requests.allSatisfy { $0["revisions"] == nil })
    }

    func testPendingResponseCarriesCompletedIdentitiesBeforeQueuedRequests() async throws {
        let store = try makeStore()
        let completed = try await enqueue(popupSnapshot(
            id: 10,
            createdAt: Date(timeIntervalSince1970: 1),
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 2, solana: 3)
        ), in: store)
        let completedResult = await store.bridge.reject(handle: completed.handle)
        XCTAssertEqual(completedResult, .persisted)
        let pending = try await enqueue(popupSnapshot(
            id: 11,
            createdAt: Date(timeIntervalSince1970: 2),
            provider: .solana
        ), in: store)
        let controller = popupController(store: store)
        let request = try popupCommand(subject: "getPendingRequests", id: 99)

        let response = await controller.dispatchJSON(
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
        XCTAssertNil(completedResponses[0]["revisions"])
    }

    func testUnavailableCatalogAllowsRetryAndRejection() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 20, provider: .ethereum, method: "requestAccounts"), in: store)
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { nil }),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor()
            )
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: 20,
            requestToken: snapshot.handle.requestToken
        )

        let response = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(response.json.keys), ["id", "state", "actions", "host", "error", "status"])
        XCTAssertEqual(response["actions"] as? [String], ["retry", "reject"])
        XCTAssertEqual(response["error"] as? String, Strings.secureApprovalSetupRequired)
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil((response["review"] as? [String: Any])?["reviewToken"])
        XCTAssertNil(response["canReject"])

        let retry = await controller.dispatchJSON(
            request: try popupCommand(
                subject: "retryApproval",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            ),
            profileIdentifier: nil
        )
        XCTAssertEqual(retry["actions"] as? [String], ["retry", "reject"])

        let rejected = await controller.dispatchJSON(
            request: try popupCommand(
                subject: "rejectRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            ),
            profileIdentifier: nil
        )
        XCTAssertEqual(rejected["status"] as? String, "ok")
        XCTAssertEqual(rejected["state"] as? String, "missing")
        let events = await store.events()
        XCTAssertEqual(events, ["reject"])
    }

    func testChangedChainSwitchMaterializesImmediateResponseFromCatalog() async throws {
        let store = try makeStore()
        try await store.establishGrant(
            popupTestAccountDescriptor(), configurationKey: "https://wallet.example", profileIdentifier: nil
        )
        let snapshot = try await enqueue(popupSwitchSnapshot(
            id: 24, address: popupTestAccount().address, requestedChainId: "0xa"
        ), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var catalogReads = 0
        var preparations = 0
        let admission = DappRequestAdmission(
            store: store,
            requestProcessor: CompactPopupAccessProcessor { request, access in
                preparations += 1
                XCTAssertEqual(access.identity, catalog.identity)
                return .immediate(.ethereumChain("0xa"))
            },
            reviewCatalog: {
                catalogReads += 1
                return catalog
            }
        )
        let disposition = await admission.materialize(handle: snapshot.handle)
        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(catalogReads, 1)
        XCTAssertEqual(preparations, 1)
        let loadCount = await store.loadCount()
        XCTAssertEqual(loadCount, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["complete"])
    }

    func testUnknownNonemptySwitchPersistsWithoutReadingCatalog() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSwitchSnapshot(
            id: 26,
            address: "0x0000000000000000000000000000000000000001",
            requestedChainId: "0x7fffffffffffffff"
        ), in: store)
        let admission = DappRequestAdmission(
            store: store,
            requestProcessor: DappRequestProcessor(ethereumNetworkResolver: { _ in .missing }),
            reviewCatalog: {
                XCTFail("Wallet-independent rejection must not read the catalog")
                return nil
            }
        )
        let disposition = await admission.materialize(handle: snapshot.handle)
        XCTAssertEqual(disposition, .responseReady)
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        XCTAssertEqual(errorCode, 4902)
    }

    func testReceiptOwnedReplaySkipsWalletMaterialization() async throws {
        let nonce = ExtensionBridge.NativeDeliveryNonce(value: UUID())
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: nonce,
            owner: popupNativeDeliveryOwner(runtime: UUID())
        )
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 30,
            provider: .ethereum,
            nativeDeliveryReceipt: receipt
        ), in: store)
        var preparations = 0
        let admission = DappRequestAdmission(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .immediate(.failure(.internalError))
            },
            reviewCatalog: {
                XCTFail("Receipt-owned work must not read the catalog")
                return nil
            }
        )
        let disposition = await admission.materialize(handle: snapshot.handle)

        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testWalletDependentAdmissionDefersWithoutCatalogProvider() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 31, provider: .ethereum), in: store)
        var preparations = 0
        let admission = DappRequestAdmission(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .immediate(.failure(.internalError))
            }
        )
        let disposition = await admission.materialize(handle: snapshot.handle)
        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testAdmissionDistinguishesUnavailableSigningAccountsFromRemovedAccounts() async throws {
        for provider in [InpageProvider.ethereum, .solana] {
            for removed in [false, true] {
                let store = try makeStore()
                let snapshot = try await enqueue(popupSnapshot(
                    id: 819, provider: provider,
                    method: provider == .ethereum ? "signPersonalMessage" : "signMessage"
                ), in: store)
                let account = provider == .ethereum ? popupTestAccount() : popupSolanaTestAccount()
                let selected = SpecificWalletAccount(walletId: "wallet", account: account)
                let sibling = SpecificWalletAccount(walletId: "sibling-wallet", account: account)
                let fullCatalog = WalletReviewCatalog(accounts: [selected, sibling])
                var catalog = removed ? WalletReviewCatalog(accounts: [sibling]) : WalletReviewCatalog(
                    identity: fullCatalog.identity, orderedAccounts: [sibling], knownAccounts: fullCatalog.knownAccounts
                )
                let admission = DappRequestAdmission(
                    store: store, requestProcessor: DappRequestProcessor(), reviewCatalog: { catalog }
                )
                guard case .snapshot(let before) = await store.bridge.configurationSnapshot(
                    configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
                ) else { return XCTFail("Expected the initial grant") }

                let disposition = await admission.materialize(handle: snapshot.handle)
                let response = await store.response(handle: snapshot.handle)
                let retained = try await store.snapshot(handle: snapshot.handle)
                guard case .snapshot(let after) = await store.bridge.configurationSnapshot(
                    configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
                ) else { return XCTFail("Expected readable authority") }
                if removed {
                    XCTAssertEqual(disposition, .responseReady)
                    XCTAssertEqual(retained.phase, .responded)
                    XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int,
                                   provider == .ethereum ? ProviderResponseError.internalErrorCode : 4100)
                    if provider == .solana {
                        XCTAssertNil(after.solanaAccount)
                        XCTAssertGreaterThan(after.version.revisions.solana, before.version.revisions.solana)
                    }
                } else {
                    XCTAssertEqual(disposition, .approvalRequired)
                    XCTAssertEqual(retained.phase, .queued)
                    XCTAssertNil(response)
                    XCTAssertEqual(after.version, before.version)
                    XCTAssertEqual(after.ethereumAccount, before.ethereumAccount)
                    XCTAssertEqual(after.solanaAccount, before.solanaAccount)

                    let replay = await admission.materialize(handle: snapshot.handle)
                    XCTAssertEqual(replay, .approvalRequired)
                    catalog = fullCatalog
                    let recovered = await admission.materialize(handle: snapshot.handle)
                    XCTAssertEqual(recovered, .approvalRequired)
                    let events = await store.events()
                    XCTAssertTrue(events.isEmpty)
                }
            }
        }
    }

    func testWalletDependentImmediateResponseUsesInjectedCatalog() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 27, provider: .ethereum), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var catalogReads = 0
        var preparations = 0
        let admission = DappRequestAdmission(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .immediate(.failure(.internalError))
            },
            reviewCatalog: {
                catalogReads += 1
                return catalog
            }
        )
        let disposition = await admission.materialize(handle: snapshot.handle)
        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(catalogReads, 1)
        XCTAssertEqual(preparations, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["complete"])
    }

    func testCompletionOwnershipLossToReceiptRequiresApprovalDelivery()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 32, provider: .ethereum), in: store)
        await store.forceNextCompletionOwnershipLoss(receipt: .init(
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: popupNativeDeliveryOwner(runtime: UUID())
        ))
        var preparations = 0
        let admission = DappRequestAdmission(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .immediate(.failure(.internalError))
            },
            reviewCatalog: { WalletReviewCatalog(account: popupTestAccount()) }
        )

        let disposition = await admission.materialize(handle: snapshot.handle)

        XCTAssertEqual(disposition, .approvalRequired)
        XCTAssertEqual(preparations, 1)
    }

    func testImmediateResponsePersistenceShowsWorkingUntilReconciled() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 28, provider: .ethereum, method: "addEthereumChain"), in: store)
        await store.suspendNextCompletion()
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    return .immediate(.failure(.userRejected))
                }
            )
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )

        let state = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(state.json.keys), ["id", "state", "actions", "host", "status"])
        XCTAssertEqual(state["id"] as? Int, snapshot.handle.id)
        XCTAssertEqual(state["state"] as? String, "working")
        XCTAssertEqual(state["host"] as? String, snapshot.host)
        XCTAssertEqual(state["actions"] as? [String], [])
        XCTAssertNil(state["review"])

        try await waitForEvent("completeStarted", store: store)
        for subject in ["getApprovalState", "retryApproval"] {
            let request = try popupCommand(
                subject: subject,
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            let current = await controller.dispatchJSON(
                request: request, profileIdentifier: nil
            )
            XCTAssertEqual(current["state"] as? String, "working")
            XCTAssertEqual(current["actions"] as? [String], [])
            XCTAssertNil(current["review"])
        }
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: UUID().uuidString.lowercased(),
            payload: [:]
        )
        let approval = await controller.dispatchJSON(
            request: approve, profileIdentifier: nil
        )
        XCTAssertEqual(approval["status"] as? String, "ignored")
        XCTAssertEqual(preparations, 1)
        let workingEvents = await store.events()
        XCTAssertEqual(workingEvents, ["completeStarted"])
        await store.resumeCompletion()
        try await waitForEvent("complete", store: store)
        let pendingRequest = try popupCommand(subject: "getPendingRequests", id: 99)
        let pending = await controller.dispatchJSON(
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
        XCTAssertEqual(preparations, 1)
    }

    func testReadsPreserveCachedErrorUntilIdentityBoundRetry() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 481, provider: .ethereum, method: "addEthereumChain"), in: store)
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { _ in
                    preparations += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork()
                    )))
                }
            )
        )
        let originalToken = try await materializeToken(controller: controller, snapshot: snapshot)
        await store.forceNextClaimResult(.unavailable)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: originalToken,
            payload: [:]
        )
        _ = await controller.dispatchJSON(
            request: approve, profileIdentifier: nil
        )
        let read = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        for _ in 0..<3 {
            let state = await controller.dispatchJSON(
                request: read, profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "error")
            XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
            XCTAssertEqual(state["error"] as? String, Strings.failedToLoad)
            XCTAssertNil(state["review"])
        }
        XCTAssertEqual(preparations, 1)
        for (token, profile) in [
            (UUID().uuidString.lowercased(), nil),
            (snapshot.handle.requestToken, UUID()),
        ] {
            let retry = try popupCommand(
                subject: "retryApproval", id: snapshot.handle.id, requestToken: token
            )
            let state = await controller.dispatchJSON(
                request: retry, profileIdentifier: profile
            )
            XCTAssertEqual(state["state"] as? String, "missing")
            XCTAssertEqual(state["actions"] as? [String], [])
            XCTAssertNil(state["review"])
        }
        XCTAssertEqual(preparations, 1)
        let retry = try popupCommand(
            subject: "retryApproval",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        var restoredToken: String?
        for _ in 0..<2 {
            let state = await controller.dispatchJSON(
                request: retry, profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "review")
            XCTAssertEqual(state["actions"] as? [String], ["approve", "reject"])
            let token = try XCTUnwrap((state["review"] as? [String: Any])?["reviewToken"] as? String)
            XCTAssertNotEqual(token, originalToken)
            if let restoredToken { XCTAssertEqual(token, restoredToken) }
            restoredToken = token
        }
        XCTAssertEqual(preparations, 2)
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testImmediatePersistenceFailureRetriesExplicitlyAndDuplicateRetryDoesNotRestartWork()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 482, provider: .ethereum, method: "addEthereumChain"), in: store)
        await store.failNextCompletion()
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    return .immediate(.failure(.userRejected))
                }
            )
        )
        let read = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        _ = await controller.dispatchJSON(
            request: read, profileIdentifier: nil
        )
        try await waitForEvent("completeFailed", store: store)
        for _ in 0..<3 {
            let state = await controller.dispatchJSON(
                request: read, profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "error")
            XCTAssertEqual(state["actions"] as? [String], ["retry"])
            XCTAssertNil(state["review"])
        }
        XCTAssertEqual(preparations, 1)
        for (requestToken, profileIdentifier) in [
            (UUID().uuidString.lowercased(), nil),
            (snapshot.handle.requestToken, UUID()),
        ] {
            let retry = try popupCommand(
                subject: "retryApproval", id: snapshot.handle.id, requestToken: requestToken
            )
            let response = await controller.dispatchJSON(
                request: retry,
                profileIdentifier: profileIdentifier
            )
            XCTAssertEqual(response["state"] as? String, "missing")
        }
        XCTAssertEqual(preparations, 1)
        await store.suspendNextCompletion()
        let retry = try popupCommand(
            subject: "retryApproval",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        for _ in 0..<2 {
            let state = await controller.dispatchJSON(
                request: retry, profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "working")
            XCTAssertEqual(state["actions"] as? [String], [])
            XCTAssertNil(state["review"])
        }
        XCTAssertEqual(preparations, 2)
        try await waitForEvent("completeStarted", store: store)
        await store.resumeCompletion()
        try await waitForEvent("complete", store: store)
        let completed = await controller.dispatchJSON(
            request: retry, profileIdentifier: nil
        )
        XCTAssertEqual(completed["state"] as? String, "missing")
        XCTAssertEqual(preparations, 2)
    }

    func testImmediatePersistenceRetryCanMaterializeAReview() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 484, provider: .ethereum, method: "addEthereumChain"), in: store)
        await store.failNextCompletion()
        var preparations = 0
        var requiresReview = false
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    if requiresReview {
                        return .approval(.addEthereumChain(AddEthereumChainAction(
                            chainToAdd: popupTestNetwork()
                        )))
                    }
                    return .immediate(.failure(.userRejected))
                }
            )
        )
        let read = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        _ = await controller.dispatchJSON(
            request: read, profileIdentifier: nil
        )
        try await waitForEvent("completeFailed", store: store)
        requiresReview = true
        let failed = await controller.dispatchJSON(
            request: read, profileIdentifier: nil
        )
        XCTAssertEqual(failed["state"] as? String, "error")
        XCTAssertEqual(preparations, 1)

        let retry = try popupCommand(
            subject: "retryApproval",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let review = await controller.dispatchJSON(
            request: retry, profileIdentifier: nil
        )
        XCTAssertEqual(review["state"] as? String, "review")
        XCTAssertEqual(review["actions"] as? [String], ["approve", "reject"])
        let token = try XCTUnwrap((review["review"] as? [String: Any])?["reviewToken"] as? String)
        let repeated = await controller.dispatchJSON(
            request: retry, profileIdentifier: nil
        )
        XCTAssertEqual((repeated["review"] as? [String: Any])?["reviewToken"] as? String, token)
        XCTAssertEqual(preparations, 2)
        let events = await store.events()
        XCTAssertEqual(events, ["completeFailed"])
    }

    func testOldImmediatePersistenceCompletionPreservesReplacementFailure() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 485, provider: .ethereum, method: "addEthereumChain"), in: store)
        await store.suspendNextCompletion()
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    return .immediate(.failure(.userRejected))
                }
            )
        )
        let read = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        _ = await controller.dispatchJSON(
            request: read, profileIdentifier: nil
        )
        try await waitForEvent("completeStarted", store: store)
        await store.setNativeDeliveryReceipt(.init(
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: popupNativeDeliveryOwner(runtime: UUID())
        ), handle: snapshot.handle)
        let nativeOwned = await controller.dispatchJSON(
            request: read, profileIdentifier: nil
        )
        XCTAssertEqual(nativeOwned["state"] as? String, "working")
        XCTAssertEqual(preparations, 1)

        await store.setNativeDeliveryReceipt(nil, handle: snapshot.handle)
        await store.failNextCompletion()
        _ = await controller.dispatchJSON(
            request: read, profileIdentifier: nil
        )
        try await waitForEvent("completeFailed", store: store)
        XCTAssertEqual(preparations, 2)
        await store.resumeCompletion(result: .ownershipLost)
        try await waitForEvent("completeResumed", store: store)
        for _ in 0..<3 {
            let failed = await controller.dispatchJSON(
                request: read, profileIdentifier: nil
            )
            XCTAssertEqual(failed["state"] as? String, "error")
            XCTAssertEqual(failed["actions"] as? [String], ["retry"])
            XCTAssertEqual(failed["error"] as? String, Strings.failedToLoad)
        }
        XCTAssertEqual(preparations, 2)
    }

    func testOldImmediatePersistenceCompletionPreservesReplacementReview() async throws {
        for result in [
            ExtensionBridge.StoreMutationResult.persisted,
            .ownershipLost,
            .retryablePersistenceFailure,
        ] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 486, provider: .ethereum, method: "addEthereumChain"), in: store)
            await store.suspendNextCompletion()
            var preparations = 0
            var requiresReview = false
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor { request in
                        preparations += 1
                        if requiresReview {
                            return .approval(.addEthereumChain(AddEthereumChainAction(
                                chainToAdd: popupTestNetwork()
                            )))
                        }
                        return .immediate(.failure(.userRejected))
                    }
                )
            )
            let read = try popupCommand(
                subject: "getApprovalState", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            _ = await controller.dispatchJSON(request: read, profileIdentifier: nil)
            try await waitForEvent("completeStarted", store: store)
            await store.setNativeDeliveryReceipt(.init(
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
                owner: popupNativeDeliveryOwner(runtime: UUID())
            ), handle: snapshot.handle)
            let nativeOwned = await controller.dispatchJSON(request: read, profileIdentifier: nil)
            XCTAssertEqual(nativeOwned["state"] as? String, "working")

            await store.setNativeDeliveryReceipt(nil, handle: snapshot.handle)
            requiresReview = true
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            XCTAssertEqual(preparations, 2)

            await store.resumeCompletion(result: result)
            try await waitForEvent("completeResumed", store: store)
            for _ in 0..<3 {
                let current = await controller.dispatchJSON(request: read, profileIdentifier: nil)
                XCTAssertEqual(current["state"] as? String, "review")
                XCTAssertEqual(current["actions"] as? [String], ["approve", "reject"])
                XCTAssertEqual((current["review"] as? [String: Any])?["reviewToken"] as? String, token)
                XCTAssertNil(current["error"])
            }
            XCTAssertEqual(preparations, 2)
        }
    }

    func testQueueCleanupPreservesOtherProfileReviewAndImmediatePersistence() async throws {
        let store = try makeStore()
        let review = try await enqueue(popupSnapshot(id: 487, provider: .ethereum, method: "addEthereumChain"), in: store)
        let otherProfile = UUID()
        let immediate = try await enqueue(popupSnapshot(
            id: review.handle.id, profileIdentifier: otherProfile, provider: .ethereum
        ), in: store)
        var reviewPreparations = 0
        var immediatePreparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    if request.name == "requestAccounts" {
                        immediatePreparations += 1
                        return .immediate(.failure(.userRejected))
                    }
                    reviewPreparations += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork()
                    )))
                }
            )
        )
        let reviewToken = try await materializeToken(controller: controller, snapshot: review)
        await store.suspendNextCompletion()
        let readImmediate = try popupCommand(
            subject: "getApprovalState", id: immediate.handle.id,
            requestToken: immediate.handle.requestToken
        )
        _ = await controller.dispatchJSON(request: readImmediate, profileIdentifier: otherProfile)
        try await waitForEvent("completeStarted", store: store)
        let pending = try popupCommand(subject: "getPendingRequests", id: 99)

        for snapshot in [review, immediate] {
            let queue = await controller.dispatchJSON(
                request: pending, profileIdentifier: snapshot.handle.profileIdentifier
            )
            let requests = try XCTUnwrap(queue["requests"] as? [[String: Any]])
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?["requestToken"] as? String, snapshot.handle.requestToken)
            let currentReviewToken = try await materializeToken(controller: controller, snapshot: review)
            XCTAssertEqual(currentReviewToken, reviewToken)
            let working = await controller.dispatchJSON(
                request: readImmediate, profileIdentifier: otherProfile
            )
            XCTAssertEqual(working["state"] as? String, "working")
            XCTAssertNil(working["review"])
        }
        XCTAssertEqual(reviewPreparations, 1)
        XCTAssertEqual(immediatePreparations, 1)
        let workingEvents = await store.events()
        XCTAssertEqual(workingEvents, ["completeStarted"])

        await store.resumeCompletion()
        try await waitForEvent("complete", store: store)
        _ = await controller.dispatchJSON(request: pending, profileIdentifier: otherProfile)
        let retainedReviewToken = try await materializeToken(controller: controller, snapshot: review)
        XCTAssertEqual(retainedReviewToken, reviewToken)
        XCTAssertEqual(reviewPreparations, 1)
    }

    func testRetryNeverRematerializesNativeOwnedOrApprovingCachedErrors() async throws {
        for ownership in ["receipt", "nativeClaim", "approving"] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 483, provider: .ethereum, method: "addEthereumChain"), in: store)
            var preparations = 0
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor { _ in
                        preparations += 1
                        return .approval(.addEthereumChain(AddEthereumChainAction(
                            chainToAdd: popupTestNetwork()
                        )))
                    }
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            await store.forceNextClaimResult(.unavailable)
            let approve = try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                reviewToken: token, payload: [:]
            )
            _ = await controller.dispatchJSON(
                request: approve, profileIdentifier: nil
            )
            var nativeClaim: ExtensionBridge.ApprovalClaim?
            defer { nativeClaim?.releaseUnapproved() }
            if ownership == "receipt" {
                await store.setNativeDeliveryReceipt(ExtensionBridge.NativeDeliveryReceipt(
                    nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
                    owner: popupNativeDeliveryOwner(runtime: UUID())
                ), handle: snapshot.handle)
            } else if ownership == "nativeClaim" {
                let authorization = try await store.prepareNativeApproval(handle: snapshot.handle, decision: .addEthereumChain)
                guard case .claimed(let claim) = await store.claimNativeExecution(consent: authorization) else { return XCTFail("Expected native execution claim") }
                nativeClaim = claim
            } else {
                try await store.holdForeignClaim(handle: snapshot.handle)
            }
            let retry = try popupCommand(
                subject: "retryApproval", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            let state = await controller.dispatchJSON(
                request: retry, profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "working", ownership)
            XCTAssertEqual(state["actions"] as? [String], [], ownership)
            XCTAssertNil(state["review"], ownership)
            XCTAssertEqual(preparations, 1, ownership)
        }
    }

    func testColdControllerShowsWorkingForApprovingSnapshot() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 22, provider: .ethereum, method: "addEthereumChain", phase: .approving), in: store)
        var preparationCount = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparationCount += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork()
                    )))
                }
            )
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )

        let response = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "working")
        XCTAssertEqual(response["host"] as? String, snapshot.host)
        XCTAssertNil((response["review"] as? [String: Any])?["reviewToken"])
        XCTAssertEqual(preparationCount, 0)
    }

    func testReceiptOwnedApprovalStateInvalidatesCachedReview() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 31, provider: .ethereum, method: "addEthereumChain"), in: store)
        var preparationCount = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparationCount += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork()
                    )))
                }
            )
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let initial = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )
        let initialToken = try XCTUnwrap((initial["review"] as? [String: Any])?["reviewToken"] as? String)
        XCTAssertEqual(preparationCount, 1)
        let receipt = ExtensionBridge.NativeDeliveryReceipt(
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: popupNativeDeliveryOwner(runtime: UUID())
        )
        await store.setNativeDeliveryReceipt(receipt, handle: snapshot.handle)

        let owned = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(owned.json.keys), ["id", "state", "actions", "host", "status"])
        XCTAssertEqual(owned["state"] as? String, "working")
        XCTAssertEqual(owned["host"] as? String, snapshot.host)
        XCTAssertNil((owned["review"] as? [String: Any])?["reviewToken"])
        XCTAssertEqual(preparationCount, 1)

        await store.setNativeDeliveryReceipt(nil, handle: snapshot.handle)
        let restored = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )
        let restoredToken = try XCTUnwrap((restored["review"] as? [String: Any])?["reviewToken"] as? String)
        XCTAssertNotEqual(restoredToken, initialToken)
        XCTAssertEqual(preparationCount, 2)
    }

    func testCachedControllerShowsWorkingAfterForeignClaim() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 23, provider: .ethereum, method: "addEthereumChain"), in: store)
        let controller = popupController(store: store)
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let initial = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )
        XCTAssertNotNil((initial["review"] as? [String: Any])?["reviewToken"])
        try await store.holdForeignClaim(handle: snapshot.handle)

        let response = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "working")
        XCTAssertEqual(response["host"] as? String, snapshot.host)
        XCTAssertNil((response["review"] as? [String: Any])?["reviewToken"])
    }

    func testSelectionCatalogRemovalRequiresSecureSetup() async throws {
        var refreshEvents = [String]()
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        let catalogAvailable = LockedTestValue(true)
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 21), in: store)
        let processor = CompactPopupProcessor { request in
            .approval(.switchAccount(SelectAccountAction(
                coinType: nil,
                selectedAccounts: [],
                initiallyConnectedProviders: [.ethereum],
                network: nil
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: {
                    refreshEvents.append("catalog")
                    return catalogAvailable.value ? catalog : nil
                }
            ),
            loadsTransactionContext: false,
            invalidateNetworkCache: { refreshEvents.append("invalidate") },
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: 21,
            requestToken: snapshot.handle.requestToken
        )
        _ = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )
        refreshEvents.removeAll()
        catalogAvailable.value = false
        let response = await controller.dispatchJSON(
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(response.json.keys), ["id", "state", "actions", "host", "error", "status"])
        XCTAssertEqual(response["actions"] as? [String], ["retry", "reject"])
        XCTAssertEqual(response["error"] as? String, Strings.secureApprovalSetupRequired)
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil((response["review"] as? [String: Any])?["reviewToken"])
        XCTAssertEqual(refreshEvents, ["catalog"])
    }

    func testAccountSelectionRejectsInvalidEntriesWithoutClaimingOrDroppingAccounts() async throws {
        let firstAccount = WalletAccount(
            address: WalletCoreProxyTestVectors.sequentialSolanaAddress,
            coin: .solana,
            derivation: .solanaSolana,
            derivationPath: "m/44'/501'/0'/0'",
            publicKey: "",
            extendedPublicKey: ""
        )
        let secondAccount = WalletAccount(
            address: WalletCoreProxyTestVectors.oneSolanaAddress,
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

        let catalog = WalletReviewCatalog(accounts: accountsByAddress.values.map {
            SpecificWalletAccount(walletId: "wallet", account: $0)
        })

        var selections = [
            [firstAccount, firstAccount],
            [firstAccount, secondAccount],
            [wrongCoinAccount],
        ].map { selectedAccounts in
            selectedAccounts.map { account in
                [
                    "walletId": "wallet",
                    "address": account.address,
                    "coin": account.coin.correspondingInpageProvider.rawValue,
                    "derivationPath": account.derivationPath,
                ]
            }
        }
        let validSelection = selections[0][0]
        for provider in ["unknown", "multiple"] {
            var invalidSelection = validSelection
            invalidSelection["coin"] = provider
            XCTAssertThrowsError(try popupCommand(
                subject: "approveRequest", id: 40,
                requestToken: "00000000-0000-4000-8000-000000000040",
                reviewToken: "00000000-0000-4000-8000-000000000041",
                payload: ["selectedAccounts": [validSelection, invalidSelection]]
            ), provider)
        }
        for (key, value) in [
            ("address", firstAccount.address.uppercased()),
            ("address", "invalid-address"),
            ("walletId", "another-wallet"),
            ("derivationPath", secondAccount.derivationPath),
        ] {
            var invalidSelection = validSelection
            invalidSelection[key] = value
            selections.append([invalidSelection])
        }

        for (index, selectedAccounts) in selections.enumerated() {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 40 + index, provider: .solana), in: store)
            var resolveCount = 0
            let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
                resolveCount += 1
                return approvedFailureForTesting(.userRejected, permit: permit)
            }) { request in
                .approval(.selectAccount(SelectAccountAction(
                    coinType: .solana,
                    selectedAccounts: [],
                    initiallyConnectedProviders: [],
                    network: nil
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(
                    reviewCatalog: { catalog }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: processor
                )
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
                    "selectedAccounts": selectedAccounts,
                ]
            )

            let response = await controller.dispatchJSON(
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
                requestToken: snapshot.handle.requestToken
            )
            let state = await controller.dispatchJSON(
                request: stateRequest,
                profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, "review")
            XCTAssertEqual(state["error"] as? String, Strings.somethingWentWrong)
            XCTAssertEqual((state["review"] as? [String: Any])?["reviewToken"] as? String, token)
        }
    }

    func testAccountSelectionPreservesSelectedNetworkAndNormalizedAddressThroughExecution() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 43, provider: .ethereum), in: store)
        let account = WalletAccount(
            address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            coin: .ethereum,
            derivation: .default,
            derivationPath: popupTestAccount().derivationPath,
            publicKey: "",
            extendedPublicKey: ""
        )
        let catalog = WalletReviewCatalog(account: account)
        let network = popupTransactionNetwork()
        var executionCount = 0
        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            executionCount += 1
            guard case .accountSelection(_, let selection) = approval.kind else {
                XCTFail("Expected account selection")
                return .rollback
            }
            XCTAssertEqual(selection.accounts, catalog.orderedAccounts)
            XCTAssertEqual(selection.network, network)
            return ApprovedCompletion.accountSelection(permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
        }) { _, _ in
            .approval(.selectAccount(SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: network
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }),
            loadsTransactionContext: false,
            selectionNetworkResolver: { $0 == network.chainIdHexString ? network : nil },
            approvalNetworkResolver: { $0 == network.chainId ? .resolved(ResolvedEthereumNetwork(network: network, source: .custom)) : .missing },
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let command = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "selectedAccounts": [[
                    "walletId": "wallet",
                    "address": account.address.uppercased(),
                    "coin": "ethereum",
                    "derivationPath": account.derivationPath,
                ]],
                "chainId": network.chainIdHexString,
            ]
        )

        let response = await controller.dispatchJSON(request: command, profileIdentifier: nil)
        let completed = await store.response(handle: snapshot.handle)

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(completed?["result"] as? [String], [account.address])
    }

    func testSelectionDraftPreservesPreparedActionAndReviewRevision() throws {
        let account = SpecificWalletAccount(walletId: "wallet", account: popupTestAccount())
        let network = popupTransactionNetwork()
        for switchesAccount in [false, true] {
            let fixture = try ApprovedExecutionTestFixture()
            if switchesAccount {
                try fixture.establishGrant(popupTestAccountDescriptor())
                try fixture.establishGrant(WalletAccountDescriptor(walletID: "wallet", account: popupSolanaTestAccount()))
            }
            let snapshot = try fixture.enqueue(
                id: 1, name: switchesAccount ? "switchAccount" : "requestAccounts",
                provider: switchesAccount ? .unknown : .ethereum,
                body: switchesAccount ? ["latestConfigurations": []] : ["address": "", "chainId": "0x1"]
            )
            let action = SelectAccountAction(
                coinType: switchesAccount ? nil : .ethereum,
                selectedAccounts: [],
                initiallyConnectedProviders: switchesAccount ? [.ethereum, .solana] : [],
                network: nil
            )
            let session = PopupRequestSession(intent: try reviewIntentForTesting(
                binding: XCTUnwrap(snapshot.requestBinding),
                action: switchesAccount ? .switchAccount(action) : .selectAccount(action)
            ), transactionApprovalOperations: unusedPopupTransactionOperations())
            let token = session.reviewToken
            let revision = session.presentationRevision
            session.selectionDraft = .init(selectedAccounts: [account], network: network)

            let prepared: SelectAccountAction
            let reviewed: SelectAccountAction
            switch (session.preparedAction, session.reviewAction) {
            case (.selectAccount(let original), .selectAccount(let current)),
                 (.switchAccount(let original), .switchAccount(let current)):
                prepared = original
                reviewed = current
            default:
                return XCTFail("Selection draft changed the action kind")
            }
            XCTAssertTrue(prepared.selectedAccounts.isEmpty)
            XCTAssertEqual(prepared.network, switchesAccount ? Networks.ethereum : nil)
            XCTAssertEqual(reviewed.selectedAccounts, [account])
            XCTAssertEqual(reviewed.network, network)
            XCTAssertEqual(reviewed.coinType, prepared.coinType)
            XCTAssertEqual(reviewed.initiallyConnectedProviders, prepared.initiallyConnectedProviders)
            XCTAssertEqual(session.reviewToken, token)
            XCTAssertEqual(session.presentationRevision, revision)
            guard case .review(let presentation) = session.presentation else {
                return XCTFail("Expected selection presentation")
            }
            let presented: SelectAccountAction
            switch presentation.content {
            case .selectAccount(let action):
                XCTAssertFalse(switchesAccount)
                presented = action
            case .switchAccount(let action):
                XCTAssertTrue(switchesAccount)
                presented = action
            default:
                return XCTFail("Selection presentation changed the action kind")
            }
            XCTAssertEqual(presented.selectedAccounts, reviewed.selectedAccounts)
            XCTAssertEqual(presented.network, reviewed.network)
            XCTAssertEqual(presentation.reviewToken, token)
        }
    }

    func testTransactionPresentationRetainsEditsAndSessionWithoutChangingIntent() async throws {
        let fixture = try ApprovedExecutionTestFixture()
        try fixture.establishGrant(popupTestAccountDescriptor(), network: popupTransactionNetwork())
        let snapshot = try fixture.enqueue(id: 43, name: "signTransaction", provider: .ethereum, body: [
            "address": popupTestAccount().address,
            "chainId": popupTransactionNetwork().chainIdHexString,
            "object": ["from": popupTestAccount().address,
                       "to": popupReadyTransaction().to,
                       "nonce": "0x0", "gas": "0x5208", "gasPrice": "0xa", "value": "0x0"],
        ])
        let session = PopupRequestSession(intent: try reviewIntentForTesting(
            binding: XCTUnwrap(snapshot.requestBinding), action: popupTransactionAction()
        ), transactionApprovalOperations: popupImmediateTransactionOperations())
        let transaction = try XCTUnwrap(session.transaction)
        defer { session.invalidate() }
        transaction.start()
        await settleTransactionPreparation(transaction)
        guard case .approveTransaction(let original) = session.preparedAction else {
            return XCTFail("Expected transaction intent")
        }
        XCTAssertTrue(transaction.applyEdits(.custom(.init(
            nonce: "7", gasPriceGwei: "0.00000002",
            maxPriorityFeePerGasGwei: nil, maxFeePerGasGwei: nil
        )), chain: popupTransactionNetwork()))
        await settleTransactionPreparation(transaction)
        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertTrue(session.acceptClaim(token: token))
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertNotEqual(session.reviewToken, token)
        session.rotateReviewToken()

        for _ in 0..<2 {
            guard case .review(let presentation) = session.presentation,
                  case .approveTransaction(let action, let presented) = presentation.content,
                  case .approveTransaction(let canonical) = session.preparedAction else {
                return XCTFail("Expected transaction presentation")
            }
            XCTAssertTrue(presented === transaction)
            XCTAssertEqual(presented.snapshot.transaction.decimalNonceString, "7")
            XCTAssertEqual(presented.snapshot.transaction.preparedFee, .legacy(gasPrice: 20))
            XCTAssertEqual(action.transaction.id, original.transaction.id)
            XCTAssertEqual(action.transaction.nonce, original.transaction.nonce)
            XCTAssertEqual(action.transaction.preparedFee, original.transaction.preparedFee)
            XCTAssertEqual(canonical.transaction.nonce, original.transaction.nonce)
            XCTAssertEqual(canonical.transaction.preparedFee, original.transaction.preparedFee)
        }
    }

    func testReviewPresentationTitlesCoverEveryAction() throws {
        let selection = SelectAccountAction(coinType: .ethereum, selectedAccounts: [], initiallyConnectedProviders: [], network: nil)
        let message = SignMessageAction(subject: .signPersonalMessage, walletId: "wallet", account: popupTestAccount(),
            meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8))))
        guard case .approveTransaction(let action) = popupTransactionAction() else {
            return XCTFail("Expected transaction action")
        }
        let transaction = PopupTransactionSession(action: action, operations: unusedPopupTransactionOperations())
        let cases: [(PopupRequestSession.ReviewContent, String)] = [
            (.selectAccount(selection), Strings.connectWallet),
            (.switchAccount(selection), Strings.switchAccount),
            (.approveMessage(message), message.subject.title),
            (.approveTransaction(action: action, transaction: transaction), Strings.sendTransaction),
            (.addEthereumChain(.init(chainToAdd: popupTestNetwork())), Strings.addNetwork),
        ]
        let presenter = PopupApprovalStatePresenter()
        for (content, title) in cases {
            let state = presenter.state(id: 43, presentation: .review(.init(
                reviewToken: UUID(), content: content, reviewCatalog: nil, feedback: nil
            )))
            guard case .review(let review, _, _) = state.content else {
                return XCTFail("Expected review title")
            }
            XCTAssertEqual(review.title, title)
        }
    }

    func testSelectionCatalogFailureRebuildsReviewAndRequiresExplicitRetryNetwork() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 705, provider: .ethereum), in: store)
        let account = popupTestAccount()
        var catalog = WalletReviewCatalog(account: account)
        var failNextCatalogRead = false
        var preparations = 0
        var executions = 0
        let network = popupTransactionNetwork()
        let processor = CompactPopupAccessProcessor(execute: { request, approval, signer, permit in
            executions += 1
            guard case .accountSelection(_, let selection) = approval.kind else {
                XCTFail("Expected account selection")
                return .rollback
            }
            XCTAssertEqual(selection.accounts, catalog.orderedAccounts)
            XCTAssertEqual(selection.network, network)
            return ApprovedCompletion.accountSelection(permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
        }) { _, _ in
            preparations += 1
            return .approval(.selectAccount(.init(
                coinType: .ethereum, selectedAccounts: [],
                initiallyConnectedProviders: [], network: nil
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: {
                if failNextCatalogRead {
                    failNextCatalogRead = false
                    return nil
                }
                return catalog
            }),
            loadsTransactionContext: false,
            selectionNetworkResolver: { $0 == network.chainIdHexString ? network : nil },
            approvalNetworkResolver: { $0 == network.chainId ? .resolved(ResolvedEthereumNetwork(network: network, source: .custom)) : .missing },
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        await store.observeNextClaim { _ in failNextCatalogRead = true }
        let selected = [
            "walletId": "wallet", "address": account.address,
            "coin": "ethereum", "derivationPath": account.derivationPath,
        ]
        let first = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token,
            payload: ["selectedAccounts": [selected], "chainId": network.chainIdHexString,
                      ]
        )
        let failed = await controller.dispatchJSON(request: first, profileIdentifier: nil)
        XCTAssertEqual(failed["state"] as? String, "error")
        XCTAssertEqual(failed["actions"] as? [String], ["retry", "reject"])
        XCTAssertNil(failed["review"])
        let retried = await controller.dispatchJSON(request: try popupCommand(
            subject: "retryApproval", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        ), profileIdentifier: nil)
        let retriedReview = try XCTUnwrap(retried["review"] as? [String: Any])
        let retryToken = try XCTUnwrap(retriedReview["reviewToken"] as? String)
        XCTAssertEqual(retried["state"] as? String, "review")
        XCTAssertNotEqual(retryToken, token)
        XCTAssertEqual((retriedReview["accounts"] as? [[String: Any]])?.first?["isSelected"] as? Bool, true)
        XCTAssertEqual(executions, 0)

        let invalid = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: retryToken,
            payload: ["selectedAccounts": [selected, selected], ]
        )
        let invalidResponse = await controller.dispatchJSON(request: invalid, profileIdentifier: nil)
        let retained = try XCTUnwrap(invalidResponse["review"] as? [String: Any])
        XCTAssertEqual(retained["reviewToken"] as? String, retryToken)
        XCTAssertEqual((retained["accounts"] as? [[String: Any]])?.first?["isSelected"] as? Bool, true)

        let missingNetwork = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: retryToken,
            payload: ["selectedAccounts": [selected]]
        ), profileIdentifier: nil)
        XCTAssertEqual(missingNetwork["state"] as? String, "review")
        XCTAssertEqual(executions, 0)
        let eventsBeforeRetry = await store.events()
        XCTAssertEqual(eventsBeforeRetry, ["claim", "returnToReview"])
        let retry = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: retryToken,
            payload: ["selectedAccounts": [selected], "chainId": network.chainIdHexString]
        )
        _ = await controller.dispatchJSON(request: retry, profileIdentifier: nil)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(preparations, 2)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "returnToReview", "claim", "complete"])

        let next = try await enqueue(popupSnapshot(id: 706, provider: .unknown), in: store)
        let nextToken = try await materializeToken(controller: controller, snapshot: next)
        await store.observeNextClaim { _ in failNextCatalogRead = true }
        let nextApproval = try popupCommand(
            subject: "approveRequest", id: next.handle.id,
            requestToken: next.handle.requestToken, reviewToken: nextToken,
            payload: ["selectedAccounts": [selected], "chainId": network.chainIdHexString,
                      ]
        )
        let nextFailed = await controller.dispatchJSON(request: nextApproval, profileIdentifier: nil)
        XCTAssertEqual(nextFailed["state"] as? String, "error")
        XCTAssertEqual(nextFailed["actions"] as? [String], ["retry", "reject"])
        catalog = WalletReviewCatalog(accounts: [SpecificWalletAccount(walletId: "replacement-wallet", account: account)])
        let stillFailed = await controller.dispatchJSON(request: try popupCommand(
            subject: "getApprovalState", id: next.handle.id,
            requestToken: next.handle.requestToken
        ), profileIdentifier: nil)
        XCTAssertEqual(stillFailed["state"] as? String, "error")
        XCTAssertEqual(stillFailed["error"] as? String, nextFailed["error"] as? String)
        let refreshed = await controller.dispatchJSON(request: try popupCommand(
            subject: "retryApproval", id: next.handle.id,
            requestToken: next.handle.requestToken
        ), profileIdentifier: nil)
        let refreshedReview = try XCTUnwrap(refreshed["review"] as? [String: Any])
        XCTAssertNotEqual(refreshedReview["reviewToken"] as? String, nextToken)
        XCTAssertEqual((refreshedReview["accounts"] as? [[String: Any]])?.first?["isSelected"] as? Bool, false)
        XCTAssertEqual(preparations, 4)
    }

    func testSelectionPersistsFailureWhenNetworkDisappearsAfterClaim() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 707, provider: .ethereum), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(account: account)
        let network = popupTransactionNetwork()
        var networkAvailable = true
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }),
            loadsTransactionContext: false,
            selectionNetworkResolver: { _ in networkAvailable ? network : nil },
            approvalNetworkResolver: { _ in networkAvailable ? .resolved(ResolvedEthereumNetwork(network: network, source: .custom)) : .missing },
            executionEnvironment: .init(
                requestProcessor: CompactPopupAccessProcessor(execute: { _, _, _, permit in
                    XCTFail("Removed network must not execute")
                    return .rollback
                }) { _, _ in
                    .approval(.selectAccount(.init(
                        coinType: .ethereum, selectedAccounts: Set(catalog.orderedAccounts),
                        initiallyConnectedProviders: [], network: network
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        await store.observeNextClaim { _ in networkAvailable = false }
        let response = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token,
            payload: [
                "selectedAccounts": [["walletId": "wallet", "address": account.address,
                                      "coin": "ethereum", "derivationPath": account.derivationPath]],
                "chainId": network.chainIdHexString,
            ]
        ), profileIdentifier: nil)
        XCTAssertEqual(response["status"] as? String, "ok")
        let error = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
        let events = await store.events()
        XCTAssertEqual(error, ProviderResponseError.internalErrorCode)
        XCTAssertFalse(committed)
        XCTAssertEqual(events, ["claim", "complete"])
        let retried = try await retryApproval(controller: controller, snapshot: snapshot)
        XCTAssertEqual(retried["state"] as? String, "missing")
    }

    func testSelectionResolvesNetworkLossBetweenReviewAndApproval() async throws {
        for temporarilyUnavailable in [false, true] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 708, provider: .ethereum), in: store)
            let account = popupTestAccount()
            let catalog = WalletReviewCatalog(account: account)
            let network = popupTransactionNetwork()
            let available = ApprovalNetworkResolution.resolved(.init(network: network, source: .custom))
            var resolution = available
            var executions = 0
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }),
                loadsTransactionContext: false,
                selectionNetworkResolver: { _ in resolution == available ? network : nil },
                approvalNetworkResolver: { _ in resolution },
                executionEnvironment: .init(
                    requestProcessor: CompactPopupAccessProcessor(execute: { _, _, _, permit in
                        executions += 1
                        return ApprovedCompletion.accountSelection(permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
                    }) { _, _ in
                        .approval(.selectAccount(.init(
                            coinType: .ethereum, selectedAccounts: Set(catalog.orderedAccounts),
                            initiallyConnectedProviders: [], network: network
                        )))
                    }
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            resolution = temporarilyUnavailable ? .unavailable : .missing
            let payload: [String: Any] = [
                "selectedAccounts": [["walletId": "wallet", "address": account.address,
                                      "coin": "ethereum", "derivationPath": account.derivationPath]],
                "chainId": network.chainIdHexString,
            ]
            let approve = try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: token, payload: payload
            )
            let first = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
            XCTAssertEqual(executions, 0)
            let error = await store.completedErrorCode(handle: snapshot.handle)
            let events = await store.events()
            if !temporarilyUnavailable {
                XCTAssertEqual(error, ProviderResponseError.internalErrorCode)
                XCTAssertEqual(events, ["claim", "complete"])
                continue
            }

            XCTAssertNil(error)
            XCTAssertEqual(first["state"] as? String, "error")
            XCTAssertEqual(first["actions"] as? [String], ["retry", "reject"])
            XCTAssertEqual(events, ["claim", "returnToReview"])
            resolution = available
            let polled = await controller.dispatchJSON(request: try popupCommand(
                subject: "getApprovalState", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            ), profileIdentifier: nil)
            XCTAssertEqual(polled["state"] as? String, "error")
            _ = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
            XCTAssertEqual(executions, 0)
            let reviewed = try await retryApproval(controller: controller, snapshot: snapshot)
            let freshToken = try XCTUnwrap((reviewed["review"] as? [String: Any])?["reviewToken"] as? String)
            XCTAssertNotEqual(freshToken, token)
            _ = await controller.dispatchJSON(request: try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: freshToken, payload: payload
            ), profileIdentifier: nil)
            let finalEvents = await store.events()
            XCTAssertEqual(executions, 1)
            XCTAssertEqual(finalEvents, ["claim", "returnToReview", "claim", "complete"])
        }
    }

    func testStaleReviewTokenRejectsApproveAndMutation() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 3, provider: .ethereum, method: "addEthereumChain"), in: store)
        let controller = popupController(store: store)
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: 3,
            requestToken: snapshot.handle.requestToken
        )
        let state = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertNotNil((state["review"] as? [String: Any])?["reviewToken"] as? String)

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
            let response = await controller.dispatchJSON(
                request: request,
                profileIdentifier: nil
            )
            XCTAssertEqual(response["status"] as? String, "ignored")
        }
        let staleEvents = await store.events()
        XCTAssertTrue(staleEvents.isEmpty)
    }

    func testAddChainApprovalSkipsRevisionsAndRejectUsesSingleActionPath() async throws {
        let store = try makeStore()
        let approved = try await enqueue(popupSnapshot(id: 4, provider: .ethereum, method: "addEthereumChain"), in: store)
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
            payload: [:]
        )
        let approvalResponse = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let approvalEvents = await store.events()
        XCTAssertEqual(approvalResponse["status"] as? String, "ok")
        XCTAssertEqual(approvalEvents, ["claim", "complete"])
        let approvalWasCommitted = await store.completedApprovalWasCommitted(
            handle: approved.handle
        )
        XCTAssertTrue(approvalWasCommitted)

        let rejected = try await enqueue(popupSnapshot(id: 5, provider: .ethereum, method: "addEthereumChain"), in: store)
        _ = try await materializeToken(
            controller: controller,
            snapshot: rejected
        )
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: 5,
            requestToken: rejected.handle.requestToken
        )
        _ = await controller.dispatchJSON(
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
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 25, provider: .ethereum, method: "addEthereumChain"), in: store)
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork()
                    )))
                }
            )
        )
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )

        let response = await controller.dispatchJSON(
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
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 27, provider: .ethereum, method: "addEthereumChain"), in: store)
            var preparations = 0
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor { request in
                        preparations += 1
                        return .approval(.addEthereumChain(AddEthereumChainAction(
                            chainToAdd: popupTestNetwork()
                        )))
                    }
                )
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

            let response = await controller.dispatchJSON(
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

    func testAuthenticationFailureReleasesClaimAndRequiresExplicitRetry() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 6, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                unlockWallets: { _, _ in .canceled }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 6,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let releaseEvents = await store.events()
        XCTAssertEqual(releaseEvents, ["claim", "abandon"])
        let refreshed = try popupCommand(
            subject: "getApprovalState",
            id: 6,
            requestToken: snapshot.handle.requestToken
        )
        let state = await controller.dispatchJSON(
            request: refreshed,
            profileIdentifier: nil
        )
        XCTAssertEqual(state["state"] as? String, "error")
        XCTAssertNil(state["review"])
        XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
    }

    func testUnavailableAuthenticationKeepsFeedbackUntilFreshReviewRetry() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 725, provider: .ethereum, method: "signPersonalMessage"
        ), in: store)
        var authentications = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(unlockWallets: { _, _ in
                authentications += 1
                return authentications == 1 ? .unavailable : .canceled
            }),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor()
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        )
        let failed = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(failed["state"] as? String, "error")
        XCTAssertEqual(failed["error"] as? String, Strings.somethingWentWrong)
        XCTAssertEqual(failed["actions"] as? [String], ["retry", "reject"])
        XCTAssertNil(failed["review"])

        let stale = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(stale["status"] as? String, "ignored")
        XCTAssertEqual(stale["error"] as? String, Strings.somethingWentWrong)
        XCTAssertEqual(authentications, 1)

        let retried = await controller.dispatchJSON(request: try popupCommand(
            subject: "retryApproval", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        ), profileIdentifier: nil)
        let freshToken = try XCTUnwrap((retried["review"] as? [String: Any])?["reviewToken"] as? String)
        XCTAssertEqual(retried["state"] as? String, "review")
        XCTAssertNil(retried["error"])
        XCTAssertNotEqual(freshToken, token)
        let oldApproval = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(oldApproval["status"] as? String, "ignored")
        XCTAssertEqual(authentications, 1)

        let cancelled = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: freshToken, payload: [:]
        ), profileIdentifier: nil)
        XCTAssertEqual(cancelled["state"] as? String, "error")
        XCTAssertNil(cancelled["review"])
        XCTAssertEqual(cancelled["error"] as? String, Strings.approvalInterrupted)
        XCTAssertEqual(authentications, 2)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon", "claim", "abandon"])
    }

    func testFailedClaimReleaseDoesNotRestoreActionableReview() async throws {
        for result in [
            ExtensionBridge.StoreMutationResult.retryablePersistenceFailure,
            .ownershipLost,
        ] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 476, provider: .ethereum, method: "signPersonalMessage"), in: store)
            var originalClaim: ExtensionBridge.ApprovalClaim?
            if result == .retryablePersistenceFailure {
                await store.forceNextAbandonResult(result)
            } else {
                await store.observeNextClaim { originalClaim = $0 }
            }
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(
                    unlockWallets: { _, _ in
                        if result == .ownershipLost {
                            do {
                                let claim = try XCTUnwrap(originalClaim)
                                let released = await store.bridge.abandon(claim: claim)
                                XCTAssertEqual(released, .persisted)
                                try await store.holdForeignClaim(handle: snapshot.handle)
                            } catch {
                                XCTFail("Failed to transfer claim ownership: \(error)")
                            }
                        }
                        return .canceled
                    }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
                        XCTFail("A failed release must not sign")
                        return approvedFailureForTesting(.internalError, permit: permit)
                    }) { request in
                        .approval(.approveMessage(SignMessageAction(
                            subject: .signPersonalMessage,
                            walletId: "wallet",
                            account: popupTestAccount(),
                            meta: "reviewed",
                            payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                        )))
                    }
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            let approve = try popupCommand(
                subject: "approveRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                reviewToken: token,
                payload: [:]
            )
            _ = await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
            let stateRequest = try popupCommand(
                subject: "getApprovalState",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            let state = await controller.dispatchJSON(
                request: stateRequest,
                profileIdentifier: nil
            )
            XCTAssertEqual(state["state"] as? String, result == .retryablePersistenceFailure ? "error" : "working")
            XCTAssertNil((state["review"] as? [String: Any])?["reviewToken"])
            XCTAssertEqual(state["actions"] as? [String], result == .retryablePersistenceFailure ? ["retry", "reject"] : [])
            if result == .retryablePersistenceFailure {
                XCTAssertEqual(state["error"] as? String, Strings.failedToLoad)
            }
            let repeated = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
            XCTAssertEqual(repeated["status"] as? String, "ignored")
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "abandon"])
        }
    }

    func testSigningApprovalTakesExecutionDeadlineFromNativeClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let store = try makeStore(clock: { now })
        let snapshot = try await enqueue(popupSnapshot(id: 59, provider: .ethereum, method: "signPersonalMessage"), in: store)
        var capturedDeadline: Date?
        await store.observeNextClaim { capturedDeadline = $0.executionDeadline }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(unlockWallets: { _, _ in .canceled }),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { _ in
                    .approval(.approveMessage(SignMessageAction(
                        subject: .signPersonalMessage, walletId: "wallet", account: popupTestAccount(),
                        meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                    )))
                },
                clock: { now }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        )
        _ = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(capturedDeadline, now.addingTimeInterval(150))
    }

    func testAuthenticationDeadlineReleasesClaimAndInvalidatesSignerRegardlessOfTimerOrder() async throws {
        for timeoutWins in [false, true] {
            let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_900_000_000))
            let store = try makeStore(clock: { clock.now })
            let snapshot = try await enqueue(popupSnapshot(
                id: 603, provider: .ethereum, method: "signPersonalMessage"
            ), in: store)
            let catalog = WalletReviewCatalog(account: popupTestAccount())
            let signingAccess = PopupRecordingWalletSigningAccess()
            var signer: WalletSigningSession!
            let unlockGate = makeGate()
            let timeoutGate = makeGate()
            let cancelled = timeoutWins ? expectation(description: "deadline cancels authentication") : nil
            let finished = expectation(description: "approval releases at deadline")
            let timerReturned = expectation(description: "authentication timer returned")
            var authenticationStarted = false
            var executionCount = 0
            var observedDeadline: Date?
            await store.observeNextClaim { claim in
                clock.now = claim.executionDeadline.addingTimeInterval(-0.01)
            }
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { catalog },
                    unlockWallets: { _, authorization in
                        signer = WalletSigningSession(
                            signingAccess, authorization: authorization,
                            isCurrent: { true }, acquireCommitLease: { WalletExecutionLease(release: {}) },
                            clock: { clock.now }
                        )
                        authenticationStarted = true
                        return await withTaskCancellationHandler {
                            await unlockGate.wait()
                            return .unlocked(catalog: catalog, session: signer)
                        } onCancel: {
                            cancelled?.fulfill()
                        }
                    }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupAccessProcessor(execute: { request, _, _, permit in
                        executionCount += 1
                        return approvedFailureForTesting(.internalError, permit: permit)
                    }) { _, _ in
                        .approval(.approveMessage(SignMessageAction(
                            subject: .signPersonalMessage, walletId: "wallet", account: popupTestAccount(),
                            meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                        )))
                    },
                    clock: { clock.now },
                    waitForExecutionDeadline: { deadline in
                        observedDeadline = deadline
                        await timeoutGate.wait()
                        if !timeoutWins { XCTAssertTrue(Task.isCancelled) }
                        clock.now = deadline
                        timerReturned.fulfill()
                    }
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            let request = try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
            )
            let approval = Task { @MainActor in
                _ = await controller.dispatchJSON(request: request, profileIdentifier: nil)
                finished.fulfill()
            }
            try await waitForCondition { authenticationStarted && observedDeadline != nil }
            XCTAssertEqual(try XCTUnwrap(observedDeadline).timeIntervalSince(clock.now), 0.01, accuracy: 0.001)
            if timeoutWins {
                await timeoutGate.open()
            } else {
                clock.now = try XCTUnwrap(observedDeadline)
                await unlockGate.open()
            }
            await fulfillment(of: [finished] + [cancelled].compactMap { $0 }, timeout: 1)
            await approval.value
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "abandon"])
            let retained = try await store.snapshot(handle: snapshot.handle)
            XCTAssertNotEqual(retained.phase, .approving)
            XCTAssertEqual(executionCount, 0)
            XCTAssertTrue(signingAccess.operations.isEmpty)

            await unlockGate.open()
            try await waitForCondition { signingAccess.invalidationCount > 0 }
            XCTAssertFalse(signer.validateCurrent())
            XCTAssertEqual(executionCount, 0)
            XCTAssertTrue(signingAccess.operations.isEmpty)
            let afterLateResult = await store.events()
            XCTAssertEqual(afterLateResult, events)
            await timeoutGate.open()
            await fulfillment(of: [timerReturned], timeout: 1)
        }
    }

    func testAuthenticationPreflightCatalogAndExecutionShareOneDeadline() async throws {
        let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_900_000_000))
        let deadline = clock.now.addingTimeInterval(150)
        let store = try makeStore(clock: { clock.now })
        let snapshot = try await enqueue(popupSnapshot(
            id: 726, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let authenticationGate = makeGate()
        let executionGate = makeGate()
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var deadlines = [Date]()
        var cancelledTimers = 0
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        var executionStarted = false
        var transaction = popupReadyTransaction()
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }) { _, authorization in
                await authenticationGate.wait()
                return .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
            },
            loadsTransactionContext: false,
            transactionApprovalOperations: TransactionApprovalOperations(
                prepare: { incoming, _, _ in
                    let source = PopupPreparationSource()
                    transaction = popupPreparedTransaction(incoming)
                    source.update(transaction)
                    source.resolve(.success(transaction))
                    return source.stream
                },
                preflight: { _, _ in
                    let source = PopupPreflightSource()
                    preflightCompletion = source.resolve
                    return try await source.value(cancellation: nil)
                }
            ),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, _, permit in
                    executionStarted = true
                    await executionGate.wait()
                    return approvedFailureForTesting(.userRejected, permit: permit)
                }) { _ in .approval(popupTransactionAction()) },
                clock: { clock.now },
                waitForExecutionDeadline: { value in
                    deadlines.append(value)
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { cancelledTimers += 1 }
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let request = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        )
        let task = Task { await controller.dispatchJSON(request: request, profileIdentifier: nil) }
        try await waitForCondition { deadlines.count == 1 }
        clock.now = deadline.addingTimeInterval(-50)
        await authenticationGate.open()
        try await waitForCondition { deadlines.count == 2 && preflightCompletion != nil }
        clock.now = deadline.addingTimeInterval(-5)
        preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
        try await waitForCondition { deadlines.count == 4 && executionStarted }
        XCTAssertEqual(deadlines, [deadline, deadline, deadline, deadline])
        await executionGate.open()
        _ = await task.value
        try await waitForCondition { cancelledTimers == 4 }
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "complete"])
    }

    func testPreflightWarningAtDeadlineDoesNotRestoreCorrectionReview() async throws {
        let clock = CompactExecutionClock(Date(timeIntervalSince1970: 1_900_000_000))
        let deadline = clock.now.addingTimeInterval(150)
        let store = try makeStore(clock: { clock.now })
        let snapshot = try await enqueue(popupSnapshot(
            id: 727, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        let material = PopupRecordingWalletSigningAccess()
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }) { _, authorization in
                .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(material, authorization: authorization))
            },
            loadsTransactionContext: false,
            transactionApprovalOperations: TransactionApprovalOperations(
                prepare: { transaction, _, _ in
                    let source = PopupPreparationSource()
                    let prepared = popupPreparedTransaction(transaction)
                    source.update(prepared)
                    source.resolve(.success(prepared))
                    return source.stream
                },
                preflight: { transaction, _ in
                    let source = PopupPreflightSource()
                    var updated = transaction
                    updated.replacePreparedFee(.legacy(gasPrice: 25), provenance: .init(gasPrice: .automatic))
                    source.resolve(.walletManagedUpdated(updated, popupTransactionEstimate()))
                    clock.now = deadline
                    return try await source.value(cancellation: nil)
                }
            ),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                    XCTFail("An expired warning must not execute")
                    return .rollback
                }) { _ in
                    preparations += 1
                    return .approval(popupTransactionAction())
                },
                clock: { clock.now }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let response = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        ), profileIdentifier: nil)
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil(response["review"])
        XCTAssertEqual(response["actions"] as? [String], ["retry", "reject"])
        XCTAssertTrue(material.operations.isEmpty)
        XCTAssertEqual(material.invalidationCount, 1)
        let polled = await controller.dispatchJSON(request: try popupCommand(
            subject: "getApprovalState", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        ), profileIdentifier: nil)
        XCTAssertEqual(polled["state"] as? String, "error")
        XCTAssertNil(polled["review"])
        XCTAssertEqual(preparations, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])
    }

    func testSupersededAuthenticationInvalidatesSignerAndPreservesReplacementReview() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 608, provider: .ethereum, method: "signPersonalMessage"
        ), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        let signingAccess = PopupRecordingWalletSigningAccess()
        let unlockGate = makeGate()
        let started = expectation(description: "authentication started")
        var signer: WalletSigningSession!
        var originalClaim: ExtensionBridge.ApprovalClaim?
        var preparations = 0
        var executions = 0
        await store.observeNextClaim { originalClaim = $0 }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    signer = WalletSigningSession(
                        signingAccess, authorization: authorization,
                        isCurrent: { true }, acquireCommitLease: { WalletExecutionLease(release: {}) }
                    )
                    started.fulfill()
                    await unlockGate.wait()
                    return .unlocked(catalog: catalog, session: signer)
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupAccessProcessor(execute: { request, _, _, permit in
                    executions += 1
                    return approvedFailureForTesting(.internalError, permit: permit)
                }) { _, _ in
                    preparations += 1
                    return .approval(.approveMessage(SignMessageAction(
                        subject: .signPersonalMessage, walletId: "wallet", account: popupTestAccount(),
                        meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                    )))
                }
            )
        )
        let originalToken = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: originalToken, payload: [:]
        )
        let approval = Task { @MainActor in
            await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        }
        await fulfillment(of: [started], timeout: 1)
        let released = await store.bridge.abandon(claim: try XCTUnwrap(originalClaim))
        XCTAssertEqual(released, .persisted)
        await store.setNativeDeliveryReceipt(.init(
            nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            owner: popupNativeDeliveryOwner(runtime: UUID())
        ), handle: snapshot.handle)
        let read = try popupCommand(
            subject: "getApprovalState", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let nativeOwned = await controller.dispatchJSON(request: read, profileIdentifier: nil)
        XCTAssertEqual(nativeOwned["state"] as? String, "working")
        await store.setNativeDeliveryReceipt(nil, handle: snapshot.handle)
        let replacementToken = try await materializeToken(controller: controller, snapshot: snapshot)
        XCTAssertNotEqual(replacementToken, originalToken)
        XCTAssertEqual(preparations, 2)

        await unlockGate.open()
        _ = await approval.value
        XCTAssertFalse(signer.validateCurrent())
        XCTAssertGreaterThan(signingAccess.invalidationCount, 0)
        XCTAssertTrue(signingAccess.operations.isEmpty)
        XCTAssertEqual(executions, 0)
        let current = await controller.dispatchJSON(request: read, profileIdentifier: nil)
        XCTAssertEqual(current["state"] as? String, "review")
        XCTAssertEqual(current["actions"] as? [String], ["approve", "reject"])
        XCTAssertEqual((current["review"] as? [String: Any])?["reviewToken"] as? String, replacementToken)
        XCTAssertNil(current["error"])
        XCTAssertEqual(preparations, 2)
    }

    func testMessageApprovalRetainsReviewedActionAndUsesFreshUnlockedAccess() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 60, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        let unlockedCatalog = WalletReviewCatalog(
            accounts: catalog.orderedAccounts,
            identity: catalog.identity
        )
        var preparations = 0
        var catalogReads = 0
        var executions = 0
        var events = [String]()
        let authenticationGate = makeGate()
        var authenticationStarted = false
        var authenticatedAccess: WalletSigningSession?
        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            executions += 1
            events.append("execute")
            XCTAssertNotNil(walletAccess)
            XCTAssertTrue(authenticatedAccess?.validateCurrent() == true)
            XCTAssertEqual(authenticatedAccess?.approvedAccount, popupTestAccountDescriptor())
            guard case .signing(_, .signature(.ethereumPersonalMessage(let payload))) = approval.kind else {
                XCTFail("Expected the reviewed message")
                return approvedFailureForTesting(.internalError, permit: permit)
            }
            XCTAssertEqual(payload, Data("reviewed".utf8))
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _, access in
            preparations += 1
            events.append("prepare")
            XCTAssertEqual(access.identity, catalog.identity)
            XCTAssertEqual(access.orderedAccounts, catalog.orderedAccounts)
            return .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: {
                    catalogReads += 1
                    return catalog
                },
                unlockWallets: { _, authorization in
                    XCTAssertEqual(authorization.approvedAccount, popupTestAccountDescriptor())
                    events.append("authenticate")
                    authenticationStarted = true
                    await authenticationGate.wait()
                    let access = makeWalletSigningSessionForTesting(authorization: authorization)
                    authenticatedAccess = access
                    return .unlocked(catalog: unlockedCatalog, session: access)
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        let dispatch = Task { @MainActor in
            await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { authenticationStarted }
        XCTAssertEqual(preparations, 1)
        let readsBeforeAuthentication = catalogReads
        await authenticationGate.open()
        let response = await dispatch.value

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(preparations, 1)
        XCTAssertGreaterThan(catalogReads, readsBeforeAuthentication)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(events, ["prepare", "authenticate", "execute"])
    }

    func testPopupRejectsSignerBoundToAnotherReviewedCatalogAccount() async throws {
        for transactionApproval in [false, true] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 810, provider: .ethereum, method: transactionApproval ? "signTransaction" : "signPersonalMessage"), in: store)
            let account = popupTestAccount()
            let approvedAccount = popupTestAccountDescriptor()
            let otherAccount = WalletAccountDescriptor(walletID: "other-wallet", account: account)
            let catalog = WalletReviewCatalog(accounts: [
                SpecificWalletAccount(walletId: approvedAccount.walletID, account: account),
                SpecificWalletAccount(walletId: otherAccount.walletID, account: account),
            ])
            var returnedSigner: WalletSigningSession!
            let transaction = popupReadyTransaction()
            let action: DappRequestAction = transactionApproval
                ? .approveTransaction(SendTransactionAction(
                    transaction: transaction,
                    resolvedNetwork: .init(network: popupTransactionNetwork(), source: .custom),
                    walletId: approvedAccount.walletID,
                    account: account
                ))
                : .approveMessage(SignMessageAction(
                    subject: .signPersonalMessage,
                    walletId: approvedAccount.walletID,
                    account: account,
                    meta: "reviewed",
                    payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                ))
            var preparations = 0
            var executions = 0
            let processor = CompactPopupProcessor(execute: { request, _, _, permit in
                executions += 1
                return approvedFailureForTesting(.internalError, permit: permit)
            }) { _ in
                preparations += 1
                return .approval(action)
            }
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { catalog },
                    unlockWallets: { _, authorization in
                        returnedSigner = makeWalletSigningSessionForTesting(authorization: walletSigningAuthorizationForTesting(approvedAccount: otherAccount, handle: authorization.handle, deadline: authorization.signingDeadline))
                        XCTAssertEqual(authorization.approvedAccount, approvedAccount)
                        return .unlocked(catalog: catalog, session: returnedSigner)
                    }
                ),
                loadsTransactionContext: false,
                transactionApprovalOperations: TransactionApprovalOperations(
                    prepare: { transaction, _, _ in
                        let source = PopupPreparationSource()
                        let prepared = popupPreparedTransaction(transaction)
                        source.update(prepared)
                        source.resolve(.success(prepared))
                        return source.stream
                    },
                    preflight: { transaction, _ in
                        let source = PopupPreflightSource()
                        XCTFail("A mismatched signer must not reach transaction preflight")
                        source.resolve(.unavailable(transaction, popupTransactionEstimate()))
                        return try await source.value(cancellation: nil)
                    }
                ),
                approvalNetworkResolver: popupApprovalNetwork,
                executionEnvironment: .init(
                    requestProcessor: processor
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            let response = await controller.dispatchJSON(request: try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: token,
                payload: [:]
            ), profileIdentifier: nil)

            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(response["state"] as? String, "error")
            XCTAssertNil(response["review"])
            let retry = try await retryApproval(controller: controller, snapshot: snapshot)
            XCTAssertEqual(retry["state"] as? String, "review")
            XCTAssertNotEqual((retry["review"] as? [String: Any])?["reviewToken"] as? String, token)
            XCTAssertEqual(preparations, 2)
            XCTAssertEqual(executions, 0)
            XCTAssertFalse(returnedSigner.validateCurrent())
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "abandon"])
        }
    }

    func testPopupSignerSignsOnlyReviewedAccountAndPayloadOnce() async throws {
        let accounts = [popupTestAccount(), WalletAccount(
            address: "0x0000000000000000000000000000000000000002",
            coin: .ethereum, derivation: .custom,
            derivationPath: "m/44'/60'/0'/0/1", publicKey: "", extendedPublicKey: ""
        )]
        let catalog = WalletReviewCatalog(accounts: accounts.map {
            SpecificWalletAccount(walletId: "wallet", account: $0)
        })
        let backingAccess = PopupRecordingWalletSigningAccess()
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 811, provider: .ethereum, method: "signPersonalMessage"), in: store)
        var executions = 0
        let processor = CompactPopupProcessor(execute: { request, _, signer, permit in
            executions += 1
            guard let signer,
                  case .success(.response) = await signer.sign(),
                  case .failure(.authorizationUnavailable) = await signer.sign() else {
                XCTFail("Only the first approved signing attempt may succeed")
                return .rollback
            }
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage, walletId: "wallet", account: accounts[0],
                meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(
                        backingAccess, authorization: authorization
                    ))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        _ = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token,
            payload: [:]
        ), profileIdentifier: nil)

        XCTAssertEqual(executions, 1)
        XCTAssertEqual(backingAccess.operations.count, 1)
        let operation = try XCTUnwrap(backingAccess.operations.first)
        XCTAssertEqual(operation.approvedAccount, WalletAccountDescriptor(walletID: "wallet", account: accounts[0]))
        XCTAssertEqual(operation.handle, snapshot.handle)
        guard case .signature(.ethereumPersonalMessage(let message)) = operation.payload else {
            return XCTFail("Expected the reviewed personal-sign payload")
        }
        XCTAssertEqual(message, Data("reviewed".utf8))
    }

    func testMessageApprovalPersistsDenialWhenAccountDisappears() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 61, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        let emptyCatalog = WalletReviewCatalog(accounts: [], identity: catalog.identity)
        var preparations = 0
        var authenticationCount = 0
        var staleResolveCount = 0
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            staleResolveCount += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            preparations += 1
            return .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    return .unlocked(catalog: emptyCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        let response = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(response["status"] as? String, "ok")
        let error = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
        XCTAssertEqual(error, ProviderResponseError.internalErrorCode)
        XCTAssertFalse(committed)
        let retry = try await retryApproval(controller: controller, snapshot: snapshot)
        XCTAssertEqual(retry["state"] as? String, "missing")
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(staleResolveCount, 0)
        let storeEvents = await store.events()
        XCTAssertEqual(storeEvents, ["claim", "complete"])
    }

    func testApprovalDispatchAwaitsAuthenticationAndFinalPersistence() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 30, provider: .ethereum, method: "signPersonalMessage"), in: store)
        await store.suspendNextCompletion()
        let authenticationGate = makeGate()
        var authenticationStarted = false
        var dispatchCompleted = false
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    authenticationStarted = true
                    await authenticationGate.wait()
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForCondition { authenticationStarted }
        XCTAssertFalse(dispatchCompleted)
        let authenticationEvents = await store.events()
        XCTAssertEqual(authenticationEvents, ["claim"])

        await authenticationGate.open()
        try await waitForEvent("completeStarted", store: store)
        XCTAssertFalse(dispatchCompleted)

        await store.resumeCompletion()
        let response = await dispatch.value
        let completionEvents = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(
            completionEvents,
            ["claim", "completeStarted", "complete"]
        )
    }

    func testExecutingApprovalIgnoresPopupRetryAndStaleActions() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 31, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let executionGate = makeGate()
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var authenticationCount = 0
        var executionCount = 0
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            executionCount += 1
            await executionGate.wait()
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    return .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        }

        try await waitForCondition { executionCount == 1 }
        let pending = try popupCommand(subject: "getPendingRequests", id: 99)
        let queue = await controller.dispatchJSON(request: pending, profileIdentifier: nil)
        let queued = try XCTUnwrap(queue["requests"] as? [[String: Any]])
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?["requestToken"] as? String, snapshot.handle.requestToken)
        for subject in ["getApprovalState", "retryApproval"] {
            let command = try popupCommand(
                subject: subject,
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )
            let response = await controller.dispatchJSON(request: command, profileIdentifier: nil)
            XCTAssertEqual(response["state"] as? String, "working")
            XCTAssertEqual(response["actions"] as? [String], [])
            XCTAssertNil(response["review"])
        }
        let repeated = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let rejected = await controller.dispatchJSON(request: reject, profileIdentifier: nil)
        XCTAssertEqual(repeated["status"] as? String, "ignored")
        XCTAssertEqual(rejected["status"] as? String, "ignored")
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(executionCount, 1)
        let pendingEvents = await store.events()
        XCTAssertEqual(pendingEvents, ["claim"])

        await executionGate.open()
        let response = await dispatch.value
        let events = await store.events()
        let approvalWasCommitted = await store.completedApprovalWasCommitted(handle: snapshot.handle)
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "complete"])
        XCTAssertTrue(approvalWasCommitted)
        XCTAssertEqual(executionCount, 1)
    }

    func testBroadcastCheckpointsBeforeSendAndCompletion() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 7, provider: .ethereum, method: "signTransaction"), in: store)
        let expectedNetwork = ResolvedEthereumNetwork(network: popupTransactionNetwork(), source: .custom)
        let sender = PopupBroadcastSender { _, network in
            XCTAssertEqual(network, expectedNetwork)
            XCTAssertEqual(network.rpcURL, expectedNetwork.rpcURL)
            XCTAssertEqual(network.allowsAlchemyAuthorization, expectedNetwork.allowsAlchemyAuthorization)
            await store.record("send")
            return .failure(.rpc(.serverError(4001, Strings.canceled)))
        }
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            XCTAssertTrue(permit.isExecuting)
            return await popupPreparedBroadcast(permit: permit, signer: walletAccess)
        }) { request in
            .approval(popupTransactionAction())
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization)) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor,
                broadcastSender: sender
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 7,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let broadcastEvents = await store.events()
        XCTAssertEqual(
            broadcastEvents,
            ["claim", "checkpoint", "send", "complete"]
        )
    }

    func testConsumedSignerCanAcquireLeaseAndIsInvalidatedBeforeBroadcastSend() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 411, provider: .ethereum, method: "signTransaction"), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(account: account)
        let owned = PopupRecordingWalletSigningAccess()
        let leaseState = CompactExecutionLeaseState(held: false)
        var access: WalletSigningSession!
        await store.setBroadcastCheckpointHook {
            XCTAssertFalse(leaseState.isReleased)
            XCTAssertEqual(owned.invalidationCount, 1)
        }
        let sender = PopupBroadcastSender { _, _ in
                    XCTAssertFalse(access.validateCurrent())
                    XCTAssertTrue(leaseState.isReleased)
                    XCTAssertEqual(owned.invalidationCount, 1)
                    guard case .failure(.authorizationUnavailable) = await access.sign() else {
                        XCTFail("Broadcast must not retain signing authority")
                        return .failure(.rpc(.serverError(-32603, Strings.somethingWentWrong)))
                    }
                    await store.record("send")
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))

        }
        let processor = CompactPopupAccessProcessor(execute: { request, _, signer, permit in
            guard let signer,
                  case .success(.broadcast(let signed)) = await signer.sign() else {
                XCTFail("Expected approved signing before acquiring a lease")
                return .rollback
            }
            XCTAssertTrue(access.validateCurrent())
            XCTAssertTrue(leaseState.isReleased)
            await store.record("signed")
            return .broadcast(PreparedBroadcast(signed: signed))
        }) { _, _ in
            .approval(popupTransactionAction())
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    access = makeWalletSigningSessionForTesting(
                        owned, authorization: authorization,
                        acquireCommitLease: {
                            XCTAssertEqual(owned.operations.count, 1)
                            leaseState.acquire()
                            await store.record("lease")
                            return WalletExecutionLease { leaseState.release() }
                        }
                    )
                    return .unlocked(catalog: catalog, session: access)
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor,
                broadcastSender: sender
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )

        _ = await controller.dispatchJSON(request: approve, profileIdentifier: nil)

        let events = await store.events()
        XCTAssertEqual(events, ["claim", "signed", "lease", "checkpoint", "send", "complete"])
        XCTAssertEqual(owned.operations.count, 1)
    }

    func testVaultRotationDuringSigningDiscardsPreparedBroadcast()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 415, provider: .ethereum, method: "signTransaction"), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(account: account)
        let accessIsCurrent = LockedTestValue(true)
        var rotateDuringSigning = true
        let sender = PopupBroadcastSender { _, _ in
                    await store.record("broadcastSent")
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))

        }
        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            let broadcast = await popupPreparedBroadcast(permit: permit, signer: walletAccess)
            if rotateDuringSigning {
                accessIsCurrent.value = false
            }
            return broadcast
        }) { request, _ in
            .approval(popupTransactionAction())
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(authorization: authorization, isCurrent: {
                        accessIsCurrent.value
                    }))
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor,
                broadcastSender: sender
            )
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
            payload: [:]
        )

        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(events, ["claim", "abandon"])

        accessIsCurrent.value = true
        rotateDuringSigning = false
        _ = try await retryApproval(controller: controller, snapshot: snapshot)
        let retryToken = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let retry = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: retryToken,
            payload: [:]
        )
        _ = await controller.dispatchJSON(
            request: retry,
            profileIdentifier: nil
        )

        let retryEvents = await store.events()
        XCTAssertEqual(retryEvents, [
            "claim", "abandon",
            "claim", "checkpoint", "broadcastSent", "complete",
        ])
    }

    func testNativeAuthorityChangeDuringAuthenticationReleasesWithoutSigning()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 419,
            provider: .ethereum,
            method: "signPersonalMessage", revisions: popupRevisions(ethereum: 3, solana: 2)), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(account: account)
        let authenticationGate = makeGate()
        var authenticationStarted = false
        var resolveCount = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            return approvedFailureForTesting(.internalError, permit: permit)
        }) { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: account,
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    authenticationStarted = true
                    await authenticationGate.wait()
                    return .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor,
                clock: { now }
            )
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        )
        let approval = Task { @MainActor in
            await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { authenticationStarted }
        await store.setAuthorityCurrent(false)
        await authenticationGate.open()
        _ = await approval.value

        XCTAssertEqual(resolveCount, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])
    }

    func testVaultAuthenticationCancellationRequiresExplicitRetry()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 412, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(account: account)
        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            XCTFail("Cancellation must not sign")
            return approvedFailureForTesting(.internalError, permit: permit)
        }) { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: account,
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, _ in .canceled }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let state = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(events, ["claim", "abandon"])
        XCTAssertEqual(state["state"] as? String, "error")
        XCTAssertNil(state["review"])
        XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
        XCTAssertEqual(state["error"] as? String, Strings.approvalInterrupted)
        XCTAssertNil(state["secureSetupRequired"])
    }

    func testCancelledTransactionAuthenticationRequiresFreshReviewAndRejectsOldCommands() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 721, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var reviewPreparations = 0
        var preparationInputs = [Transaction]()
        var preparationGasChecks = [Bool]()
        var preparedGasLimits = [String?]()
        var authentications = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }) { _, _ in
                authentications += 1
                return .canceled
            },
            loadsTransactionContext: false,
            transactionApprovalOperations: TransactionApprovalOperations(
                prepare: { transaction, forceGasCheck, _ in
                    let source = PopupPreparationSource()
                    preparationInputs.append(transaction)
                    preparationGasChecks.append(forceGasCheck)
                    var prepared = popupPreparedTransaction(transaction)
                    if forceGasCheck { prepared.gas = "0x10000" }
                    preparedGasLimits.append(prepared.gas)
                    source.estimate(popupTransactionEstimate())
                    source.update(prepared)
                    source.resolve(.success(prepared))
                    return source.stream
                },
                preflight: { _, _ in
                    let source = PopupPreflightSource()
                    XCTFail("Cancelled authentication must not start preflight")
                    return try await source.value(cancellation: nil)
                }
            ),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                    XCTFail("Cancelled authentication must not execute")
                    return .rollback
                }) { _ in
                    reviewPreparations += 1
                    return .approval(popupTransactionAction())
                }
            )
        )
        let initialToken = try await materializeToken(controller: controller, snapshot: snapshot)
        let edited = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "applyTransactionEdits", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: initialToken,
            payload: ["mode": "custom", "nonce": "7", "gasPriceGwei": "0.000000025"]
        ), profileIdentifier: nil)
        let editedToken = try XCTUnwrap((edited["review"] as? [String: Any])?["reviewToken"] as? String)
        let approve = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: editedToken, payload: [:]
        )

        let cancelled = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(cancelled["state"] as? String, "error")
        XCTAssertEqual(cancelled["error"] as? String, Strings.approvalInterrupted)
        XCTAssertNil(cancelled["review"])
        XCTAssertEqual(reviewPreparations, 1)
        let polled = await controller.dispatchJSON(request: try popupCommand(
            subject: "getApprovalState", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        ), profileIdentifier: nil)
        XCTAssertEqual(polled["state"] as? String, "error")
        XCTAssertNil(polled["review"])
        XCTAssertEqual(reviewPreparations, 1)
        let retried = try await retryApproval(controller: controller, snapshot: snapshot)
        let review = try XCTUnwrap(retried["review"] as? [String: Any])
        let freshToken = try XCTUnwrap(review["reviewToken"] as? String)
        let editor = try XCTUnwrap(review["editor"] as? [String: Any])
        XCTAssertEqual(retried["state"] as? String, "review")
        XCTAssertNil(retried["error"])
        XCTAssertNotEqual(freshToken, editedToken)
        XCTAssertEqual(editor["nonce"] as? String, "0")
        XCTAssertEqual(editor["gasPriceGwei"] as? String, "0.00000001")
        XCTAssertEqual(reviewPreparations, 2)
        XCTAssertEqual(preparationInputs.count, 3)
        XCTAssertEqual(preparationGasChecks, [false, true, false])
        XCTAssertEqual(preparedGasLimits, ["0x5208", "0x10000", "0x5208"])
        let freshTransaction = try XCTUnwrap(preparationInputs.last)
        XCTAssertNil(freshTransaction.nonce)
        XCTAssertEqual(freshTransaction.preparedFee, .legacy(gasPrice: 10))
        XCTAssertNotEqual(freshTransaction.feeProvenance.gasPrice, .manual)

        let staleApproval = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        let staleEdit = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "applyTransactionEdits", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: editedToken,
            payload: ["mode": "custom", "nonce": "8", "gasPriceGwei": "0.00000003"]
        ), profileIdentifier: nil)
        XCTAssertEqual(staleApproval["status"] as? String, "ignored")
        XCTAssertEqual(staleEdit["status"] as? String, "ignored")
        let retainedReview = try XCTUnwrap(staleEdit["review"] as? [String: Any])
        XCTAssertEqual(retainedReview["reviewToken"] as? String, freshToken)
        XCTAssertEqual(retainedReview["editor"] as? NSDictionary, editor as NSDictionary)
        XCTAssertEqual(authentications, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])

        let reset = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "applyTransactionEdits", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: freshToken,
            payload: ["mode": "suggested"]
        ), profileIdentifier: nil)
        let resetEditor = try XCTUnwrap((reset["review"] as? [String: Any])?["editor"] as? [String: Any])
        XCTAssertEqual(resetEditor["nonce"] as? String, "0")
        XCTAssertEqual(resetEditor["gasPriceGwei"] as? String, "0.00000001")
    }

    func testFreshTransactionSessionUsesCurrentSuggestedNonce() async throws {
        var transaction = popupReadyTransaction()
        transaction.nonce = nil
        let network = popupTransactionNetwork()
        let action = SendTransactionAction(
            transaction: transaction, resolvedNetwork: .init(network: network, source: .custom),
            walletId: "wallet", account: popupTestAccount()
        )
        var pendingNonce = "0x5"
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                var prepared = transaction
                prepared.nonce = prepared.nonce ?? pendingNonce
                source.estimate(popupTransactionEstimate())
                source.update(prepared)
                source.resolve(.success(prepared))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()
                XCTFail("Cancelled authentication must not start preflight")
                return try await source.value(cancellation: nil)
            }
        )
        let original = PopupTransactionSession(action: action, operations: operations)
        original.start()
        await settleTransactionPreparation(original)
        XCTAssertEqual(original.snapshot.transaction.decimalNonceString, "5")
        let token = try XCTUnwrap(original.beginApproval())
        guard case .reviewRequired = await original.finishAuthentication(token: token, succeeded: false) else {
            return XCTFail("Expected a cancelled approval")
        }
        pendingNonce = "0x6"
        let restored = PopupTransactionSession(action: action, operations: operations)
        restored.start()
        await settleTransactionPreparation(restored)
        XCTAssertEqual(restored.snapshot.transaction.decimalNonceString, "6")
        XCTAssertEqual(restored.snapshot.suggestedNonce, "6")
        XCTAssertTrue(restored.applyEdits(.suggested, chain: network))
        XCTAssertEqual(restored.snapshot.transaction.decimalNonceString, "6")
    }

    func testExplicitRetryUsesFreshNetworkAndTransactionDetails() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 722, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        let originalNetwork = popupTransactionNetwork()
        let replacementNetwork = EthereumNetwork(
            chainId: originalNetwork.chainId, name: "Replacement RPC", symbol: originalNetwork.symbol,
            rpcEndpoint: .unauthenticated(URL(string: "https://replacement-rpc.example")!),
            isTestnet: true, mightShowPrice: false, explorer: nil
        )
        var network = ResolvedEthereumNetwork(network: originalNetwork, source: .custom)
        var reviewPreparations = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }) { _, _ in
                network = ResolvedEthereumNetwork(network: replacementNetwork, source: .custom)
                return .canceled
            },
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: { $0 == network.network.chainId ? .resolved(network) : .missing },
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                    XCTFail("Cancelled authentication must not execute")
                    return .rollback
                }) { _ in
                    reviewPreparations += 1
                    return .approval(.approveTransaction(.init(
                        transaction: popupReadyTransaction(), resolvedNetwork: network,
                        walletId: "wallet", account: popupTestAccount()
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let edited = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "applyTransactionEdits", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token,
            payload: ["mode": "custom", "nonce": "7", "gasPriceGwei": "0.000000025"]
        ), profileIdentifier: nil)
        let editedToken = try XCTUnwrap((edited["review"] as? [String: Any])?["reviewToken"] as? String)

        let stopped = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: editedToken, payload: [:]
        ), profileIdentifier: nil)
        XCTAssertEqual(stopped["state"] as? String, "error")
        XCTAssertNil(stopped["review"])
        XCTAssertEqual(reviewPreparations, 1)
        let response = try await retryApproval(controller: controller, snapshot: snapshot)
        let review = try XCTUnwrap(response["review"] as? [String: Any])
        let editor = try XCTUnwrap(review["editor"] as? [String: Any])
        XCTAssertEqual(response["state"] as? String, "review")
        XCTAssertNotEqual(review["reviewToken"] as? String, editedToken)
        XCTAssertEqual(review["networkName"] as? String, replacementNetwork.name)
        XCTAssertEqual(editor["nonce"] as? String, "0")
        XCTAssertEqual(editor["gasPriceGwei"] as? String, "0.00000001")
        XCTAssertEqual(reviewPreparations, 2)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])
    }

    func testCustomNetworkRetryWaitsForFreshStorageBeforeReviewingOrRejecting() async throws {
        for removed in [false, true] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 723, provider: .ethereum, method: "signTransaction"
            ), in: store)
            var definition = popupTestNetwork()
            definition.chainId = "0xa"
            let networks = CustomNetworkSnapshot(records: [definition])
            let storage = Mutex<CustomNetworkSnapshotLoadResult>(.loaded(networks))
            let cache = CustomNetworkCache(loader: { storage.withLock { $0 } })
            let resolver = NetworkResolver(
                catalog: try NetworkCatalog(records: []), catalogOwnedChainIds: [],
                customSnapshot: { cache.snapshot() }
            )
            let resolve: @MainActor @Sendable (Int) -> ApprovalNetworkResolution = { chainID in
                resolver.approvalResolution(chainId: chainID, freshCustomSnapshot: { cache.refreshSnapshot() })
            }
            let processor = DappRequestProcessor(ethereumNetworkResolver: resolve)
            let admission = DappRequestAdmission(store: store, requestProcessor: processor)
            let catalog = WalletReviewCatalog(account: popupTestAccount())
            let signingAccess = PopupRecordingWalletSigningAccess()
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }) { _, authorization in
                    storage.withLock { $0 = .corrupt }
                    return .unlocked(catalog: catalog, session: makeWalletSigningSessionForTesting(
                        signingAccess, authorization: authorization
                    ))
                },
                loadsTransactionContext: false,
                transactionApprovalOperations: popupImmediateTransactionOperations(),
                approvalNetworkResolver: resolve,
                executionEnvironment: .init(
                    requestProcessor: processor
                )
            )
            let originalToken = try await materializeToken(controller: controller, snapshot: snapshot)
            let failed = await controller.dispatchJSON(request: try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: originalToken, payload: [:]
            ), profileIdentifier: nil)
            XCTAssertEqual(failed["state"] as? String, "error")
            XCTAssertTrue(cache.snapshot().orderedEntries.isEmpty)

            for unavailable in [CustomNetworkSnapshotLoadResult.corrupt, .unavailable, .corrupt] {
                storage.withLock { $0 = unavailable }
                let disposition = await admission.materialize(handle: snapshot.handle)
                XCTAssertEqual(disposition, .approvalRequired)
                let retry = try await retryApproval(controller: controller, snapshot: snapshot)
                XCTAssertEqual(retry["state"] as? String, "error")
                XCTAssertEqual(retry["actions"] as? [String], ["retry", "reject"])
                XCTAssertNil(retry["review"])
                let retained = try await store.snapshot(handle: snapshot.handle)
                let response = await store.response(handle: snapshot.handle)
                XCTAssertEqual(retained.phase, .queued)
                XCTAssertNil(response)
            }
            let eventsBeforeRecovery = await store.events()
            XCTAssertEqual(eventsBeforeRecovery, ["claim", "returnToReview"])
            XCTAssertTrue(signingAccess.operations.isEmpty)

            storage.withLock { $0 = .loaded(removed ? .empty : networks) }
            XCTAssertTrue(cache.snapshot().orderedEntries.isEmpty)
            let recovered = try await retryApproval(controller: controller, snapshot: snapshot)
            if removed {
                try await waitForEvent("complete", store: store)
                let error = await store.completedErrorCode(handle: snapshot.handle)
                XCTAssertEqual(error, ProviderResponseError.internalErrorCode)
                let terminal = try await retryApproval(controller: controller, snapshot: snapshot)
                XCTAssertEqual(terminal["state"] as? String, "missing")
            } else {
                XCTAssertEqual(recovered["state"] as? String, "review")
                let review = try XCTUnwrap(recovered["review"] as? [String: Any])
                XCTAssertNotEqual(review["reviewToken"] as? String, originalToken)
                XCTAssertEqual(review["networkName"] as? String, definition.chainName)
                let retained = try await store.snapshot(handle: snapshot.handle)
                let response = await store.response(handle: snapshot.handle)
                XCTAssertEqual(retained.phase, .queued)
                XCTAssertNil(response)
            }
            XCTAssertTrue(signingAccess.operations.isEmpty)
        }
    }

    func testReusedTransactionRequestIDAndReplacementAccountDoNotInheritEdits() async throws {
        let store = try makeStore()
        let first = try await enqueue(popupSnapshot(
            id: 723, provider: .ethereum, method: "signTransaction"
        ), in: store)
        var catalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }),
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupAccessProcessor { _, currentCatalog in
                    let selected = currentCatalog.orderedAccounts[0]
                    return .approval(.approveTransaction(.init(
                        transaction: popupReadyTransaction(),
                        resolvedNetwork: .init(network: popupTransactionNetwork(), source: .custom),
                        walletId: selected.walletId, account: selected.account
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: first)
        let edited = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "applyTransactionEdits", id: first.handle.id,
            requestToken: first.handle.requestToken, reviewToken: token,
            payload: ["mode": "custom", "nonce": "7", "gasPriceGwei": "0.000000025"]
        ), profileIdentifier: nil)
        let editedToken = try XCTUnwrap((edited["review"] as? [String: Any])?["reviewToken"] as? String)
        let oldApproval = try popupCommand(
            subject: "approveRequest", id: first.handle.id,
            requestToken: first.handle.requestToken, reviewToken: editedToken, payload: [:]
        )
        let cancelled = await controller.dispatchJSON(request: oldApproval, profileIdentifier: nil)
        XCTAssertEqual(cancelled["state"] as? String, "error")
        XCTAssertNil(cancelled["review"])

        let original = try XCTUnwrap(first.request)
        guard case .snapshot(let authority) = await store.bridge.configurationSnapshot(
            configurationKey: original.configurationKey, profileIdentifier: nil
        ), case .revoked = await store.bridge.revoke(
            configurationKey: original.configurationKey, provider: .ethereum,
            attempt: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            expected: authority.version, profileIdentifier: nil
        ) else {
            return XCTFail("Expected the original account connection to be revoked")
        }
        let replacement = WalletAccountDescriptor(walletID: "replacement-wallet", account: popupTestAccount())
        catalog = WalletReviewCatalog(accounts: [replacement.specificAccount])
        let next = try await store.enqueue(rawObject: [
            "id": first.handle.id, "name": original.name, "provider": original.provider.rawValue,
            "body": requestBodyForTesting(original), "host": original.host,
            "configurationKey": original.configurationKey,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "workflowVersion": ExtensionBridge.workflowVersion,
        ], approvedAccount: replacement)
        XCTAssertEqual(next.handle.id, first.handle.id)
        XCTAssertNotEqual(next.handle.requestToken, first.handle.requestToken)
        XCTAssertEqual(next.request?.authorizedAccount, replacement)

        let state = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "getApprovalState", id: next.handle.id,
            requestToken: next.handle.requestToken
        ), profileIdentifier: nil)
        let review = try XCTUnwrap(state["review"] as? [String: Any])
        let editor = try XCTUnwrap(review["editor"] as? [String: Any])
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertEqual(editor["nonce"] as? String, "0")
        XCTAssertEqual(editor["gasPriceGwei"] as? String, "0.00000001")
        let stale = await controller.dispatchJSON(request: oldApproval, profileIdentifier: nil)
        XCTAssertEqual(stale["status"] as? String, "ignored")
        let unchanged = await controller.dispatchJSON(request: try popupCommand(
            subject: "getApprovalState", id: next.handle.id,
            requestToken: next.handle.requestToken
        ), profileIdentifier: nil)
        XCTAssertEqual((unchanged["review"] as? [String: Any])?["editor"] as? NSDictionary, editor as NSDictionary)
    }

    func testPreflightFeeWarningRetainsUpdatedReviewAndRetiresSignerBeforeRetry() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 724, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var reviewPreparations = 0
        var preflights = 0
        var sessions = [WalletSigningSession]()
        var materials = [PopupRecordingWalletSigningAccess]()
        var executedTransactions = [Transaction]()
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(reviewCatalog: { catalog }) { _, authorization in
                let material = PopupRecordingWalletSigningAccess()
                let session = makeWalletSigningSessionForTesting(material, authorization: authorization)
                materials.append(material)
                sessions.append(session)
                return .unlocked(catalog: catalog, session: session)
            },
            loadsTransactionContext: false,
            transactionApprovalOperations: TransactionApprovalOperations(
                prepare: { transaction, _, _ in
                    let source = PopupPreparationSource()
                    let prepared = popupPreparedTransaction(transaction)
                    source.update(prepared)
                    source.resolve(.success(prepared))
                    return source.stream
                },
                preflight: { transaction, _ in
                    let source = PopupPreflightSource()
                    preflights += 1
                    if preflights == 1 {
                        var updated = transaction
                        updated.replacePreparedFee(.legacy(gasPrice: 25), provenance: .init(gasPrice: .automatic))
                        source.resolve(.walletManagedUpdated(updated, popupTransactionEstimate()))
                    } else {
                        source.resolve(.safe(transaction, popupTransactionEstimate()))
                    }
                    return try await source.value(cancellation: nil)
                }
            ),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, approval, signer, permit in
                    if let transaction = popupExecutedTransaction(approval: approval) {
                        executedTransactions.append(transaction)
                    }
                    guard let signer, case .success = await signer.sign() else {
                        XCTFail("The fresh approval must use its newly authenticated signer")
                        return .rollback
                    }
                    return approvedFailureForTesting(.userRejected, permit: permit)
                }) { _ in
                    reviewPreparations += 1
                    return .approval(popupTransactionAction())
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        )

        let response = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        let review = try XCTUnwrap(response["review"] as? [String: Any])
        let warningToken = try XCTUnwrap(review["reviewToken"] as? String)
        let alert = try XCTUnwrap(review["alert"] as? [String: Any])
        XCTAssertEqual(response["state"] as? String, "review")
        XCTAssertNotEqual(warningToken, token)
        XCTAssertEqual(alert["title"] as? String, Strings.feesUpdated)
        XCTAssertEqual((review["editor"] as? [String: Any])?["gasPriceGwei"] as? String, "0.000000025")
        XCTAssertTrue((response["actions"] as? [String])?.contains("resolveApprovalAlert") == true)
        XCTAssertEqual(reviewPreparations, 1)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(try XCTUnwrap(sessions.first).validateCurrent())
        XCTAssertTrue(try XCTUnwrap(materials.first).operations.isEmpty)
        XCTAssertEqual(materials.first?.invalidationCount, 1)

        let stale = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(stale["status"] as? String, "ignored")
        XCTAssertEqual(sessions.count, 1)
        let acknowledged = try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "resolveApprovalAlert", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: warningToken,
            payload: ["action": "acknowledge"]
        ), profileIdentifier: nil)
        let nextReview = try XCTUnwrap(acknowledged["review"] as? [String: Any])
        let nextToken = try XCTUnwrap(nextReview["reviewToken"] as? String)
        XCTAssertNil(nextReview["alert"])
        XCTAssertEqual((nextReview["editor"] as? [String: Any])?["gasPriceGwei"] as? String, "0.000000025")
        XCTAssertTrue((acknowledged["actions"] as? [String])?.contains("approve") == true)

        _ = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: nextToken, payload: [:]
        ), profileIdentifier: nil)
        XCTAssertEqual(preflights, 2)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(executedTransactions.count, 1)
        XCTAssertEqual(executedTransactions.first?.preparedFee, .legacy(gasPrice: 25))
        XCTAssertEqual(materials.map { $0.operations.count }, [0, 1])
        XCTAssertEqual(materials.map(\.invalidationCount), [1, 1])
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon", "claim", "complete"])
    }

    func testMissingVaultDuringAuthenticationShowsSecureSetupRequired()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 413, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(account: account)
        var currentCatalog: WalletReviewCatalog? = catalog
        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            XCTFail("An unavailable vault must not sign")
            return approvedFailureForTesting(.internalError, permit: permit)
        }) { request, _ in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: account,
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { currentCatalog },
                unlockWallets: { _, _ in
                    currentCatalog = nil
                    return .unavailable
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let stopped = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertEqual(stopped["error"] as? String, Strings.approvalInterrupted)
        XCTAssertNil(stopped["review"])
        let state = try await retryApproval(controller: controller, snapshot: snapshot)
        let events = await store.events()

        XCTAssertEqual(events, ["claim", "abandon"])
        XCTAssertEqual(state["state"] as? String, "error")
        XCTAssertEqual(
            state["error"] as? String,
            Strings.secureApprovalSetupRequired
        )
        XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
        XCTAssertNil((state["review"] as? [String: Any])?["reviewToken"])
    }

    func testChangedVaultDuringAuthenticationReleasesBeforeRematerializing() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 477, provider: .ethereum, method: "signPersonalMessage"), in: store)
        let account = popupTestAccount()
        let original = WalletReviewCatalog(account: account)
        let replacement = WalletReviewCatalog(account: account)
        var currentCatalog: WalletReviewCatalog = original
        var preparedCatalogs = [WalletCatalogIdentity]()
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { currentCatalog },
                unlockWallets: { _, authorization in
                    currentCatalog = replacement
                    return .unlocked(catalog: replacement, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
                    XCTFail("A changed catalog must be reviewed before signing")
                    return approvedFailureForTesting(.internalError, permit: permit)
                }) { request, access in
                    preparedCatalogs.append(access.identity)
                    return .approval(.approveMessage(SignMessageAction(
                        subject: .signPersonalMessage,
                        walletId: "wallet",
                        account: account,
                        meta: "reviewed",
                        payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "abandon"])
        XCTAssertEqual(preparedCatalogs, [original.identity])
        _ = try await retryApproval(controller: controller, snapshot: snapshot)
        let nextToken = try await materializeToken(controller: controller, snapshot: snapshot)
        XCTAssertNotEqual(nextToken, token)
        XCTAssertEqual(preparedCatalogs, [original.identity, replacement.identity])
    }

    func testRemovedSelectedAccountDuringAuthenticationPersistsDenial() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 813, provider: .ethereum, method: "signPersonalMessage"
        ), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(accounts: [
            SpecificWalletAccount(walletId: "wallet", account: account),
            SpecificWalletAccount(walletId: "other-wallet", account: account)
        ])
        let remainingCatalog = WalletReviewCatalog(
            accounts: Array(catalog.orderedAccounts.dropFirst()), identity: catalog.identity
        )
        var currentCatalog = catalog
        var preparedAccounts = [[SpecificWalletAccount]]()
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { currentCatalog },
                unlockWallets: { _, _ in
                    currentCatalog = remainingCatalog
                    return .unavailable
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupAccessProcessor(execute: { _, _, _, permit in
                    XCTFail("An unavailable selected account must not sign")
                    return approvedFailureForTesting(.internalError, permit: permit)
                }) { _, access in
                    preparedAccounts.append(access.orderedAccounts)
                    return .approval(.approveMessage(SignMessageAction(
                        subject: .signPersonalMessage, walletId: "wallet", account: account,
                        meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let response = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        ), profileIdentifier: nil)

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(preparedAccounts, [catalog.orderedAccounts])
        let error = await store.completedErrorCode(handle: snapshot.handle)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "complete"])
        XCTAssertEqual(error, ProviderResponseError.internalErrorCode)
        let retried = try await retryApproval(controller: controller, snapshot: snapshot)
        XCTAssertEqual(retried["state"] as? String, "missing")
        XCTAssertEqual(preparedAccounts, [catalog.orderedAccounts])
    }

    func testUnavailableReviewedSigningAccountWithUsableSiblingRequiresFreshReview() async throws {
        for provider in [InpageProvider.ethereum, .solana] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 818, provider: provider,
                method: provider == .ethereum ? "signPersonalMessage" : "signMessage"
            ), in: store)
            let account = provider == .ethereum ? popupTestAccount() : popupSolanaTestAccount()
            let selected = SpecificWalletAccount(walletId: "wallet", account: account)
            let sibling = SpecificWalletAccount(walletId: "sibling-wallet", account: account)
            let catalog = WalletReviewCatalog(accounts: [selected, sibling])
            let unavailable = WalletReviewCatalog(
                identity: catalog.identity, orderedAccounts: [sibling], knownAccounts: catalog.knownAccounts
            )
            var currentCatalog = catalog
            let processor = PreparationRecordingDappRequestProcessor()
            var authentications = 0
            let signingAccess = PopupRecordingWalletSigningAccess()
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { currentCatalog },
                    unlockWallets: { _, authorization in
                        authentications += 1
                        return .unlocked(catalog: currentCatalog, session: makeWalletSigningSessionForTesting(
                            signingAccess, authorization: authorization
                        ))
                    }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: processor
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            guard case .snapshot(let before) = await store.bridge.configurationSnapshot(
                configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
            ) else { return XCTFail("Expected the reviewed grant") }
            currentCatalog = unavailable
            let stopped = await controller.dispatchJSON(request: try popupCommand(
                subject: "getApprovalState", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            ), profileIdentifier: nil)
            XCTAssertEqual(stopped["state"] as? String, "error")
            XCTAssertEqual(stopped["error"] as? String, Strings.secureApprovalSetupRequired)
            XCTAssertEqual(stopped["actions"] as? [String], ["retry", "reject"])
            XCTAssertNil(stopped["review"])
            let staleApprove = try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
            )
            _ = await controller.dispatchJSON(request: staleApprove, profileIdentifier: nil)
            let response = await store.response(handle: snapshot.handle)
            let events = await store.events()
            guard case .snapshot(let after) = await store.bridge.configurationSnapshot(
                configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
            ) else { return XCTFail("Expected the retained grant") }
            XCTAssertNil(response)
            XCTAssertTrue(events.isEmpty)
            XCTAssertEqual(processor.preparations, 1)
            XCTAssertEqual(authentications, 0)
            XCTAssertTrue(signingAccess.operations.isEmpty)
            XCTAssertEqual(after.version, before.version)
            XCTAssertEqual(after.ethereumAccount, before.ethereumAccount)
            XCTAssertEqual(after.solanaAccount, before.solanaAccount)

            currentCatalog = catalog
            let reviewed = try await retryApproval(controller: controller, snapshot: snapshot)
            let freshToken = try XCTUnwrap((reviewed["review"] as? [String: Any])?["reviewToken"] as? String)
            XCTAssertNotEqual(freshToken, token)
            let stale = await controller.dispatchJSON(request: staleApprove, profileIdentifier: nil)
            XCTAssertEqual(stale["status"] as? String, "ignored")
            XCTAssertEqual(authentications, 0)
            _ = await controller.dispatchJSON(request: try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: freshToken, payload: [:]
            ), profileIdentifier: nil)
            let completed = await store.response(handle: snapshot.handle)
            let signature = try XCTUnwrap(completed?["result"] as? String)
            let signatureData = provider == .ethereum
                ? WalletCrypto.hexData(signature) : WalletCrypto.base58Decode(string: signature)
            XCTAssertEqual(signatureData?.count, provider == .ethereum ? 65 : 64)
            XCTAssertEqual(processor.preparations, 2)
            XCTAssertEqual(authentications, 1)
            XCTAssertEqual(signingAccess.operations.count, 1)
            XCTAssertEqual(signingAccess.operations.first?.approvedAccount.walletID, selected.walletId)
        }
    }

    func testSigningContinuesWhenSiblingAccountBecomesUnavailableDuringAuthentication() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 814, provider: .ethereum, method: "signPersonalMessage"
        ), in: store)
        let account = popupTestAccount()
        let catalog = WalletReviewCatalog(accounts: [
            SpecificWalletAccount(walletId: "wallet", account: account),
            SpecificWalletAccount(walletId: "other-wallet", account: account)
        ])
        let remainingCatalog = WalletReviewCatalog(
            accounts: Array(catalog.orderedAccounts.prefix(1)), identity: catalog.identity
        )
        let currentCatalog = LockedTestValue(catalog)
        var preparations = 0
        let signingAccess = PopupRecordingWalletSigningAccess()
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { currentCatalog.value },
                unlockWallets: { _, authorization in
                    currentCatalog.value = remainingCatalog
                    return .unlocked(catalog: currentCatalog.value, session: makeWalletSigningSessionForTesting(
                        signingAccess, authorization: authorization,
                        isCurrent: {
                            currentCatalog.value.identity == catalog.identity &&
                                currentCatalog.value.orderedAccounts.contains(where: {
                                    authorization.approvedAccount.matches(walletID: $0.walletId, account: $0.account)
                                })
                        }
                    ))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: CompactPopupAccessProcessor(execute: { _, _, signer, permit in
                    guard let signer,
                          case .success(.response) = await signer.sign() else {
                        XCTFail("The available selected account must remain authorized to sign")
                        return .rollback
                    }
                    return approvedFailureForTesting(.userRejected, permit: permit)
                }) { _, _ in
                    preparations += 1
                    return .approval(.approveMessage(SignMessageAction(
                        subject: .signPersonalMessage, walletId: "wallet", account: account,
                        meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        _ = await controller.dispatchJSON(request: try popupCommand(
            subject: "approveRequest", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken, reviewToken: token, payload: [:]
        ), profileIdentifier: nil)

        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(signingAccess.operations.count, 1)
        XCTAssertEqual(signingAccess.operations.first?.approvedAccount, popupTestAccountDescriptor())
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "complete"])
    }

    func testCachedReviewsRefreshWhenAvailableAccountsChangeWithinSameGeneration() async throws {
        for (index, isSelection) in [false, true].enumerated() {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 815 + index, provider: .ethereum,
                method: isSelection ? "requestAccounts" : "signPersonalMessage"
            ), in: store)
            let account = popupTestAccount()
            let catalog = WalletReviewCatalog(accounts: [
                SpecificWalletAccount(walletId: "wallet", account: account),
                SpecificWalletAccount(walletId: "other-wallet", account: account)
            ])
            let remainingCatalog = WalletReviewCatalog(
                accounts: Array(catalog.orderedAccounts.prefix(1)), identity: catalog.identity
            )
            var currentCatalog = catalog
            var preparedAccounts = [[SpecificWalletAccount]]()
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { currentCatalog },
                    unlockWallets: { _, _ in
                        XCTFail("A stale review token must never start authentication")
                        return .unavailable
                    }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupAccessProcessor { _, access in
                        preparedAccounts.append(access.orderedAccounts)
                        if isSelection {
                            return .approval(.selectAccount(SelectAccountAction(
                                coinType: .ethereum, selectedAccounts: Set(access.orderedAccounts),
                                initiallyConnectedProviders: [], network: popupTransactionNetwork()
                            )))
                        }
                        return .approval(.approveMessage(SignMessageAction(
                            subject: .signPersonalMessage, walletId: "wallet", account: account,
                            meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                        )))
                    }
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            currentCatalog = remainingCatalog
            let response = await controller.dispatchJSON(request: try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: token,
                payload: isSelection ? [
                    "selectedAccounts": [[
                        "walletId": "other-wallet", "address": account.address,
                        "coin": "ethereum", "derivationPath": account.derivationPath
                    ]],
                    "chainId": popupTransactionNetwork().chainIdHexString
                ] : [:]
            ), profileIdentifier: nil)

            XCTAssertEqual(response["status"] as? String, "ignored")
            let refreshedReview = try XCTUnwrap(response["review"] as? [String: Any])
            let refreshedToken = try XCTUnwrap(refreshedReview["reviewToken"] as? String)
            XCTAssertNotEqual(refreshedToken, token)
            XCTAssertEqual(preparedAccounts, [catalog.orderedAccounts, remainingCatalog.orderedAccounts])
            if isSelection {
                XCTAssertEqual((refreshedReview["accounts"] as? [[String: Any]])?.count, 1)
            }
            let unchangedToken = try await materializeToken(controller: controller, snapshot: snapshot)
            XCTAssertEqual(unchangedToken, refreshedToken)
            currentCatalog = catalog
            let restoredToken = try await materializeToken(controller: controller, snapshot: snapshot)
            XCTAssertNotEqual(restoredToken, refreshedToken)
            XCTAssertEqual(preparedAccounts, [
                catalog.orderedAccounts, remainingCatalog.orderedAccounts, catalog.orderedAccounts
            ])
            let events = await store.events()
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testCachedSigningAndSelectionReviewsDetectVaultTombstone()
        async throws {
        for (index, isSelection) in [false, true].enumerated() {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 416 + index, provider: .ethereum, method: isSelection ? "requestAccounts" : "signPersonalMessage"), in: store)
            let account = popupTestAccount()
            let catalog = WalletReviewCatalog(account: account)
            var currentCatalog: WalletReviewCatalog? = catalog
            let processor = CompactPopupAccessProcessor { request, _ in
                if isSelection {
                    return .approval(.selectAccount(SelectAccountAction(
                        coinType: .ethereum,
                        selectedAccounts: [SpecificWalletAccount(
                            walletId: "wallet",
                            account: account
                        )],
                        initiallyConnectedProviders: [],
                        network: popupTransactionNetwork()
                    )))
                }
                return .approval(.approveMessage(SignMessageAction(
                    subject: .signPersonalMessage,
                    walletId: "wallet",
                    account: account,
                    meta: "reviewed",
                    payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { currentCatalog },
                    unlockWallets: { _, _ in
                        XCTFail("Unexpected wallet unlock")
                        return .unavailable
                    }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: processor
                )
            )
            _ = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )
            currentCatalog = nil
            let stateRequest = try popupCommand(
                subject: "getApprovalState",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )

            let state = await controller.dispatchJSON(
                request: stateRequest,
                profileIdentifier: nil
            )

            XCTAssertEqual(state["state"] as? String, "error")
            XCTAssertEqual(
                state["error"] as? String,
                Strings.secureApprovalSetupRequired
            )
            XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
            XCTAssertNil((state["review"] as? [String: Any])?["reviewToken"])
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
            let store = try makeStore()
            let catalog = WalletReviewCatalog(account: account)
            let processor = CompactPopupAccessProcessor { request, _ in
                if isSelection {
                    return .approval(.selectAccount(SelectAccountAction(
                        coinType: .ethereum,
                        selectedAccounts: Set(catalog.orderedAccounts),
                        initiallyConnectedProviders: [],
                        network: popupTransactionNetwork()
                    )))
                }
                return .approval(.approveMessage(SignMessageAction(
                    subject: .signPersonalMessage,
                    walletId: "wallet",
                    account: account,
                    meta: "reviewed",
                    payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { catalog },
                    unlockWallets: { _, _ in
                        XCTFail("Unexpected wallet unlock")
                        return .unavailable
                    }
                ),
                loadsTransactionContext: false,
                executionEnvironment: .init(
                    requestProcessor: processor
                )
            )
            let first = try await enqueue(popupSnapshot(id: 418, provider: .ethereum, method: isSelection ? "requestAccounts" : "signPersonalMessage"), in: store)
            let next = try await enqueue(popupSnapshot(id: 419, provider: .ethereum, method: isSelection ? "requestAccounts" : "signPersonalMessage"), in: store)
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
                    requestToken: snapshot.handle.requestToken
                )
                let state = await controller.dispatchJSON(
                    request: request,
                    profileIdentifier: nil
                )
                let renderedAccount = isSelection
                    ? ((state["review"] as? [String: Any])?["accounts"] as? [[String: Any]])?.first
                    : (state["review"] as? [String: Any])?["account"] as? [String: Any]
                XCTAssertEqual(renderedAccount?["name"] as? String, expectedName)
            }
        }
    }

    func testWalletIndependentApprovalDoesNotRequireVaultCatalog()
        async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 414, provider: .ethereum, method: "addEthereumChain"), in: store)
        let processor = CompactPopupProcessor(walletIndependent: true)
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { nil },
                unlockWallets: { _, _ in
                    XCTFail("Unexpected wallet unlock")
                    return .unavailable
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )

        let state = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertEqual((state["review"] as? [String: Any])?["kind"] as? String, "addChain")
        XCTAssertNotNil((state["review"] as? [String: Any])?["reviewToken"])
        XCTAssertNil(state["secureSetupRequired"])
    }

    func testApprovalDispatchAwaitsBroadcastSend() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 32, provider: .ethereum, method: "signTransaction"), in: store)
        let sendGate = makeGate()
        var dispatchCompleted = false
        let sender = PopupBroadcastSender { _, _ in
                    await store.record("sendStarted")
                    await sendGate.wait()
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))

        }
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            await popupPreparedBroadcast(permit: permit, signer: walletAccess)
        }) { request in
            .approval(popupTransactionAction())
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization)) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor,
                broadcastSender: sender
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatchJSON(
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
            ["claim", "checkpoint", "sendStarted"]
        )

        await sendGate.open()
        let response = await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(
            events,
            ["claim", "checkpoint", "sendStarted", "complete"]
        )
    }

    func testTransactionApprovalAwaitsSynchronousAuthenticationOutputAndPreflight() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 33, provider: .ethereum, method: "signTransaction"), in: store)
        var transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        let authenticationGate = makeGate()
        var authenticationStarted = false
        var authenticationCount = 0
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        var dispatchCompleted = false
        let operations = TransactionApprovalOperations(
            prepare: { incoming, _, _ in
                let source = PopupPreparationSource()
                transaction = popupPreparedTransaction(incoming)
                source.update(transaction)
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()
                preflightCompletion = source.resolve
                return try await source.value(cancellation: nil)
            }
        )
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            let transaction = popupExecutedTransaction(approval: approval)
            XCTAssertNotNil(transaction)
            await store.record("resolve")
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    authenticationStarted = true
                    await authenticationGate.wait()
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForCondition { authenticationStarted }
        XCTAssertFalse(dispatchCompleted)
        let duplicateApproval = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        XCTAssertEqual(duplicateApproval["status"] as? String, "ignored")
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertFalse(dispatchCompleted)
        await authenticationGate.open()
        try await waitForCondition { preflightCompletion != nil }
        XCTAssertFalse(dispatchCompleted)

        preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
        let response = await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(events, ["claim", "resolve", "complete"])
    }

    func testTransactionApprovalRetainsReviewedPayloadAndAppliesExecutionEdits() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 62, provider: .ethereum, method: "signTransaction"), in: store)
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
        var executionCount = 0
        let backingAccess = PopupRecordingWalletSigningAccess()
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                let prepared = popupPreparedTransaction(transaction)
                source.update(prepared)
                source.resolve(.success(prepared))
                return source.stream
            },
            preflight: { canonical, _ in
                let source = PopupPreflightSource()
                var approved = approvedTransaction
                approved.id = canonical.id
                source.resolve(.safe(approved, popupTransactionEstimate()))
                return try await source.value(cancellation: nil)
            }
        )
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            let transaction = popupExecutedTransaction(approval: approval)
            executionCount += 1
            guard case .signing(_, .ethereumTransaction(let reviewed, _)) = approval.kind else {
                XCTFail("Expected the reviewed transaction")
                return approvedFailureForTesting(.internalError, permit: permit)
            }
            XCTAssertEqual(reviewed.from, reviewedTransaction.from)
            XCTAssertEqual(reviewed.to, reviewedTransaction.to)
            XCTAssertEqual(reviewed.value, reviewedTransaction.value)
            XCTAssertEqual(reviewed.data, reviewedTransaction.data)
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
            guard let walletAccess,
                  case .success = await walletAccess.sign(),
                  let operation = backingAccess.operations.first,
                  case .ethereumTransaction(let boundTransaction, let boundNetwork) = operation.payload else {
                XCTFail("Expected a signer bound to the final transaction")
                return .rollback
            }
            XCTAssertEqual(operation.approvedAccount, popupTestAccountDescriptor())
            XCTAssertEqual(operation.handle, snapshot.handle)
            XCTAssertEqual(boundTransaction.nonce, approvedTransaction.nonce)
            XCTAssertEqual(boundTransaction.gas, approvedTransaction.gas)
            XCTAssertEqual(boundTransaction.preparedFee, approvedTransaction.preparedFee)
            XCTAssertEqual(boundTransaction.feeProvenance, approvedTransaction.feeProvenance)
            XCTAssertEqual(boundTransaction.from, reviewedTransaction.from)
            XCTAssertEqual(boundTransaction.to, reviewedTransaction.to)
            XCTAssertEqual(boundTransaction.value, reviewedTransaction.value)
            XCTAssertEqual(boundTransaction.data, reviewedTransaction.data)
            XCTAssertEqual(boundNetwork.network, network)
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            preparations += 1
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: reviewedTransaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(backingAccess, authorization: authorization)) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(backingAccess.operations.count, 1)
        XCTAssertEqual(backingAccess.invalidationCount, 1)
    }

    func testTransactionApprovalPreservesReviewedPayloadDespiteChangedPreflightOutput() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 63, provider: .ethereum, method: "signTransaction"), in: store)
        let reviewedTransaction = popupReadyTransaction()
        let changedTransaction = Transaction(
            id: reviewedTransaction.id,
            from: "0x0000000000000000000000000000000000000088",
            to: "0x0000000000000000000000000000000000000099",
            nonce: reviewedTransaction.nonce,
            gas: reviewedTransaction.gas,
            value: "0x99",
            data: "0xabcd",
            feeIntent: .legacy(gasPrice: 10),
            preparedFee: .legacy(gasPrice: 10),
            feeSource: .automatic
        )
        let network = popupTransactionNetwork()
        var preparations = 0
        var authenticationCount = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                let prepared = popupPreparedTransaction(transaction)
                source.update(prepared)
                source.resolve(.success(prepared))
                return source.stream
            },
            preflight: { canonical, _ in
                let source = PopupPreflightSource()
                var changed = changedTransaction
                changed.id = canonical.id
                source.resolve(.safe(changed, popupTransactionEstimate()))
                return try await source.value(cancellation: nil)
            }
        )
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            let transaction = popupExecutedTransaction(approval: approval)
            XCTAssertEqual(transaction?.from, reviewedTransaction.from)
            XCTAssertEqual(transaction?.to, reviewedTransaction.to)
            XCTAssertEqual(transaction?.value, reviewedTransaction.value)
            XCTAssertEqual(transaction?.data, reviewedTransaction.data)
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            preparations += 1
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: reviewedTransaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(resolveCount, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "complete"])
    }

    func testTransactionApprovalRejectsFreshRPCEndpointDrift() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 64, provider: .ethereum, method: "signTransaction"), in: store)
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
        var currentNetwork = ResolvedEthereumNetwork(network: reviewedNetwork, source: .custom)
        var preparations = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                let prepared = popupPreparedTransaction(transaction)
                source.update(prepared)
                source.resolve(.success(prepared))
                return source.stream
            },
            preflight: { transaction, _ in
                let source = PopupPreflightSource()
                source.resolve(.safe(transaction, popupTransactionEstimate()))
                return try await source.value(cancellation: nil)
            }
        )
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            preparations += 1
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(network: reviewedNetwork, source: .custom),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    currentNetwork = .init(network: changedNetwork, source: .custom)
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: { chainID in
                chainID == currentNetwork.network.chainId ? .resolved(currentNetwork) : .missing
            },
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        let response = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "missing")
        XCTAssertNil(response["review"])
        let error = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
        XCTAssertEqual(error, 4100)
        XCTAssertFalse(committed)
        let retry = try await retryApproval(controller: controller, snapshot: snapshot)
        XCTAssertEqual(retry["state"] as? String, "missing")
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(resolveCount, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "complete"])
    }

    func testTransactionRematerializesAfterRetryableExecutionStartFailure() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 36, provider: .ethereum, method: "signTransaction"), in: store)
        await store.failNextAuthorization()
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                let source = PopupPreparationSource()
                let prepared = popupPreparedTransaction(transaction)
                source.update(prepared)
                source.resolve(.success(prepared))
                return source.stream
            },
            preflight: { transaction, _ in
                let source = PopupPreflightSource()
                source.resolve(.safe(transaction, popupTransactionEstimate()))
                return try await source.value(cancellation: nil)
            }
        )
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            let transaction = popupExecutedTransaction(approval: approval)
            XCTAssertNotNil(transaction)
            resolveCount += 1
            await store.record("resolve")
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization)) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor
            )
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
            payload: [:]
        )

        let firstResponse = await controller.dispatchJSON(
            request: firstApproval,
            profileIdentifier: nil
        )
        XCTAssertEqual(firstResponse["status"] as? String, "ok")
        let firstEvents = await store.events()
        XCTAssertEqual(firstEvents, ["claim", "abandon"])
        XCTAssertEqual(resolveCount, 0)

        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let stopped = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertEqual(stopped["state"] as? String, "error")
        XCTAssertNil(stopped["review"])
        let state = try await retryApproval(controller: controller, snapshot: snapshot)
        let secondToken = try XCTUnwrap((state["review"] as? [String: Any])?["reviewToken"] as? String)
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertTrue((state["actions"] as? [String])?.contains("approve") == true)
        XCTAssertNotEqual(secondToken, firstToken)

        let secondApproval = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: secondToken,
            payload: [:]
        )
        let secondResponse = await controller.dispatchJSON(
            request: secondApproval,
            profileIdentifier: nil
        )

        XCTAssertEqual(secondResponse["status"] as? String, "ok")
        XCTAssertEqual(resolveCount, 1)
        let secondEvents = await store.events()
        XCTAssertEqual(
            secondEvents,
            ["claim", "abandon", "claim", "resolve", "complete"]
        )
    }

    func testTransactionPresentationChangeWhileClaimingRequiresRetry() async throws {
        try await assertTransactionPresentationChangeReturnsToReview(duringAuthorityCheck: false)
    }

    func testTransactionPresentationChangeWhileCheckingAuthorityReturnsToReview() async throws {
        try await assertTransactionPresentationChangeReturnsToReview(duringAuthorityCheck: true)
    }

    private func assertTransactionPresentationChangeReturnsToReview(duringAuthorityCheck: Bool) async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 35, provider: .ethereum, method: "signTransaction"), in: store)
        if duringAuthorityCheck {
            await store.suspendNextAuthorityCheck()
        } else {
            await store.suspendNextClaim()
        }
        var transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preparationUpdate: ((Transaction) -> Void)?
        var authenticationCount = 0
        var preflightCount = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { incoming, _, _ in
                let source = PopupPreparationSource()
                transaction = popupPreparedTransaction(incoming)
                preparationUpdate = source.update
                source.update(transaction)
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { transaction, _ in
                let source = PopupPreflightSource()
                preflightCount += 1
                source.resolve(.safe(transaction, popupTransactionEstimate()))
                return try await source.value(cancellation: nil)
            }
        )
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForEvent(duringAuthorityCheck ? "authorityCheckStarted" : "claimStarted", store: store)
        var lateTransaction = transaction
        lateTransaction.interpretation = "Late interpretation"
        preparationUpdate?(lateTransaction)
        if duringAuthorityCheck {
            await store.resumeAuthorityCheck()
        } else {
            await store.resumeClaim()
        }

        let response = await dispatch.value
        let events = await store.events()
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let state = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["status"] as? String, "ignored")
        XCTAssertEqual(events, duringAuthorityCheck ? ["authorityCheckStarted"] : ["claimStarted", "claim", "abandon"])
        XCTAssertEqual(state["state"] as? String, duringAuthorityCheck ? "review" : "error")
        XCTAssertEqual(
            (state["review"] as? [String: Any])?["dataInterpretation"] as? String,
            duringAuthorityCheck ? "Late interpretation" : nil
        )
        if duringAuthorityCheck {
            let updatedToken = try XCTUnwrap((state["review"] as? [String: Any])?["reviewToken"] as? String)
            XCTAssertNotEqual(updatedToken, token)
        } else {
            XCTAssertNil(state["review"])
            XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
            let retried = try await retryApproval(controller: controller, snapshot: snapshot)
            let freshToken = try XCTUnwrap((retried["review"] as? [String: Any])?["reviewToken"] as? String)
            XCTAssertNotEqual(freshToken, token)
        }
        let staleApproval = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(staleApproval["status"] as? String, "ignored")
        XCTAssertEqual(authenticationCount, 0)
        XCTAssertEqual(preflightCount, 0)
        XCTAssertEqual(resolveCount, 0)
    }

    func testCompletedRequestPollingSettlesPendingTransactionPreflight() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 64, provider: .ethereum, method: "signTransaction"), in: store)
        var activeClaim: ExtensionBridge.ApprovalClaim?
        await store.observeNextClaim { activeClaim = $0 }
        var transaction = popupReadyTransaction()
        let catalog = WalletReviewCatalog(account: popupTestAccount())
        var access: WalletSigningSession!
        let cancellation = PopupCancellationRecorder()
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        var dispatchCompleted = false
        var executionCount = 0
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: PopupWalletEnvironment(
                reviewCatalog: { catalog },
                unlockWallets: { _, authorization in
                    access = makeWalletSigningSessionForTesting(authorization: authorization)
                    return .unlocked(catalog: catalog, session: access)
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: TransactionApprovalOperations(
                prepare: { incoming, _, _ in
                    let source = PopupPreparationSource()
                    transaction = popupPreparedTransaction(incoming)
                    source.update(transaction)
                    source.resolve(.success(transaction))
                    return source.stream
                },
                preflight: { _, _ in
                    let source = PopupPreflightSource()
                    preflightCompletion = source.resolve
                    return try await source.value(cancellation: cancellation)
                }
            ),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { request, _, _, permit in
                    executionCount += 1
                    return approvedFailureForTesting(.userRejected, permit: permit)
                }) { _ in
                    .approval(.approveTransaction(SendTransactionAction(
                        transaction: transaction,
                        resolvedNetwork: ResolvedEthereumNetwork(
                            network: popupTransactionNetwork(),
                            source: .custom
                        ),
                        walletId: "wallet",
                        account: popupTestAccount()
                    )))
                }
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            let result = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
            dispatchCompleted = true
            return result
        }
        try await waitForCondition { preflightCompletion != nil }
        _ = try XCTUnwrap(snapshot.request)
        let released = await store.bridge.abandon(claim: try XCTUnwrap(activeClaim))
        XCTAssertEqual(released, .persisted)
        _ = await store.completeImmediate(
            handle: snapshot.handle, resolution: .failure(.userRejected)
        )
        let pending = try popupCommand(subject: "getPendingRequests", id: 99)

        _ = await controller.dispatchJSON(request: pending, profileIdentifier: nil)
        try await waitForCondition { dispatchCompleted }
        let response = await dispatch.value

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertFalse(access.validateCurrent())
        preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
        XCTAssertEqual(executionCount, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["claim", "complete", "abandon"])
    }

    func testTransactionPreflightDeadlineReleasesClaimAndIgnoresLateResults() async throws {
        for remainingAfterAuthentication in [0.05, 0] {
            let deadline = Date(timeIntervalSince1970: 1_900_000_000)
            let nativeClock = CompactExecutionClock(deadline.addingTimeInterval(-150))
            let store = try makeStore(clock: { nativeClock.now })
            let snapshot = try await enqueue(popupSnapshot(id: 65, provider: .ethereum, method: "signTransaction"), in: store)
            var transaction = popupReadyTransaction()
            let catalog = WalletReviewCatalog(account: popupTestAccount())
            var access: WalletSigningSession!
            let cancellation = PopupCancellationRecorder()
            var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
            var dispatchCompleted = false
            var executionCount = 0
            let controller = PopupRequestSessions(
                store: store,
                walletEnvironment: PopupWalletEnvironment(
                    reviewCatalog: { catalog },
                    unlockWallets: { _, authorization in
                        access = makeWalletSigningSessionForTesting(authorization: authorization)
                        nativeClock.now = deadline.addingTimeInterval(-remainingAfterAuthentication)
                        return .unlocked(catalog: catalog, session: access)
                    }
                ),
                loadsTransactionContext: false,
                transactionApprovalOperations: TransactionApprovalOperations(
                    prepare: { incoming, _, _ in
                        let source = PopupPreparationSource()
                        transaction = popupPreparedTransaction(incoming)
                        source.update(transaction)
                        source.resolve(.success(transaction))
                        return source.stream
                    },
                    preflight: { _, _ in
                        let source = PopupPreflightSource()
                        preflightCompletion = source.resolve
                        return try await source.value(cancellation: cancellation)
                    }
                ),
                approvalNetworkResolver: popupApprovalNetwork,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { request, _, _, permit in
                        executionCount += 1
                        return approvedFailureForTesting(.userRejected, permit: permit)
                    }) { _ in
                        .approval(.approveTransaction(SendTransactionAction(
                            transaction: transaction,
                            resolvedNetwork: ResolvedEthereumNetwork(
                                network: popupTransactionNetwork(), source: .custom
                            ),
                            walletId: "wallet", account: popupTestAccount()
                        )))
                    },
                    clock: { nativeClock.now }
                )
            )
            let token = try await materializeToken(controller: controller, snapshot: snapshot)
            let approve = try popupCommand(
                subject: "approveRequest", id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken, reviewToken: token,
                payload: [:]
            )
            let dispatch = Task { @MainActor in
                let response = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
                dispatchCompleted = true
                return response
            }
            defer {
                preflightCompletion?(.unavailable(transaction, popupTransactionEstimate()))
            }

            try await waitForCondition { dispatchCompleted }
            let response = await dispatch.value

            XCTAssertEqual(response["state"] as? String, "error")
            XCTAssertNil(response["review"])
            XCTAssertFalse(access.validateCurrent())
            XCTAssertEqual(preflightCompletion != nil, remainingAfterAuthentication > 0)
            if preflightCompletion != nil { XCTAssertTrue(cancellation.isCancelled) }
            preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
            XCTAssertEqual(executionCount, 0)
            let events = await store.events()
            XCTAssertEqual(events, ["claim", "abandon"])
            let stored = try await store.snapshot(handle: snapshot.handle)
            XCTAssertEqual(stored.phase, .queued)
        }
    }

    func testTransactionAlertReleasesClaimBeforeApprovalReturns() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(id: 34, provider: .ethereum, method: "signTransaction"), in: store)
        var transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        let operations = TransactionApprovalOperations(
            prepare: { incoming, _, _ in
                let source = PopupPreparationSource()
                transaction = popupPreparedTransaction(incoming)
                source.update(transaction)
                source.resolve(.success(transaction))
                return source.stream
            },
            preflight: { _, _ in
                let source = PopupPreflightSource()
                preflightCompletion = source.resolve
                return try await source.value(cancellation: nil)
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
                account: popupTestAccount()
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let owned = BorrowedWalletSignerForTesting()
        var access: WalletSigningSession!
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    access = WalletSigningSession(
                        owned, authorization: authorization, isCurrent: { true },
                        acquireCommitLease: { WalletExecutionLease(release: {}) }
                    )
                    return .unlocked(catalog: authenticationCatalog, session: access)
                }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: operations,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatchJSON(
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { preflightCompletion != nil }
        preflightCompletion?(.unavailable(transaction, popupTransactionEstimate()))
        let response = await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "abandon"])
        XCTAssertEqual(owned.invalidationCount, 1)
        XCTAssertEqual(response["state"] as? String, "review")
        XCTAssertNotNil((response["review"] as? [String: Any])?["alert"])

        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let state = await controller.dispatchJSON(
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertNotNil((state["review"] as? [String: Any])?["alert"])
    }

    func testHungBroadcastTimesOutToRecoveryAndInvokesSendOnce() async throws {
        let store = try makeStore()
        let gate = makeGate()
        let recovered = expectation(description: "recovery before sender returns")
        let late = expectation(description: "sender returned after recovery")
        let snapshot = try await enqueue(popupSnapshot(id: 8, provider: .ethereum, method: "signTransaction"), in: store)
        let sender = PopupBroadcastSender { _, _ in
                    await store.record("send")
                    await gate.wait()
                    await store.record("late")
                    late.fulfill()
                    return .failure(.rpc(.serverError(4001, Strings.canceled)))

        }
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            await popupPreparedBroadcast(permit: permit, signer: walletAccess)
        }) { request in
            .approval(popupTransactionAction())
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization)) }
            ),
            loadsTransactionContext: false,
            transactionApprovalOperations: popupImmediateTransactionOperations(),
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: processor,
                broadcastSender: sender,
                broadcastTimeoutNanoseconds: 1_000_000
            )
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
            payload: [:]
        )
        let task = Task { @MainActor in
            _ = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
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

    func testUnavailableAuthorityPreservesReviewForRetry() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 9,
            provider: .ethereum,
            method: "signPersonalMessage", revisions: popupRevisions(ethereum: 3, solana: 4)), in: store)
        var authenticationCount = 0
        var resolveCount = 0
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        await store.setAuthorityCurrent(false)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )

        let response = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(response["status"] as? String, "unavailable")
        XCTAssertEqual(events, [])
        XCTAssertNil(errorCode)
        XCTAssertEqual(authenticationCount, 0)
        XCTAssertEqual(resolveCount, 0)

        let pending = try await store.snapshot(handle: snapshot.handle)
        XCTAssertEqual(pending.phase, .queued)
        let preservedToken = try await materializeToken(controller: controller, snapshot: snapshot)
        XCTAssertEqual(preservedToken, token)

        await store.setAuthorityCurrent(true)
        let retried = await controller.dispatchJSON(request: approve, profileIdentifier: nil)
        XCTAssertEqual(retried["status"] as? String, "ok")
        XCTAssertEqual(authenticationCount, 1)
        XCTAssertEqual(resolveCount, 1)
        let retryError = await store.completedErrorCode(handle: snapshot.handle)
        XCTAssertEqual(retryError, 4001)
    }

    func testRevokedAuthorityCannotBeApproved() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 11,
            provider: .ethereum, method: "signPersonalMessage", revisions: popupRevisions(ethereum: 2, solana: 8)), in: store)
        var authenticationCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signPersonalMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "reviewed",
                payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )))
        }
        let authenticationCatalog = WalletReviewCatalog(account: popupTestAccount())
        let controller = PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(
                reviewCatalog: { authenticationCatalog },
                unlockWallets: { _, authorization in
                    authenticationCount += 1
                    return .unlocked(catalog: authenticationCatalog, session: makeWalletSigningSessionForTesting(authorization: authorization))
                }
            ),
            loadsTransactionContext: false,
            executionEnvironment: .init(
                requestProcessor: processor
            )
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let request = try XCTUnwrap(snapshot.request)
        guard case .snapshot(let authority) = await store.bridge.configurationSnapshot(
            configurationKey: request.configurationKey, profileIdentifier: nil
        ), case .revoked = await store.bridge.revoke(
            configurationKey: request.configurationKey, provider: .ethereum,
            attempt: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            expected: authority.version, profileIdentifier: nil
        ) else {
            return XCTFail("Expected account connection to be revoked")
        }
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )

        _ = await controller.dispatchJSON(
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(events, [])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(authenticationCount, 0)
    }

    #if os(macOS)
    func testNativeFinalizerDoesNotReprepareAcceptedIntent() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 814, provider: .ethereum, method: "signPersonalMessage"
        ), in: store)
        let approvedAccount = popupTestAccountDescriptor()
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .message(.init(approvedAccount: approvedAccount, solanaCluster: nil))
        )
        var catalogRefreshes = 0
        var signerCreations = 0
        var executions = 0
        let processor = CompactPopupProcessor(walletIndependent: true, execute: { _, _, _, permit in
            executions += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _ in
            XCTFail("Accepted immutable intent must not be prepared again")
            return .immediate(.failure(.internalError))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor
            ),
            refreshWalletCatalog: {
                catalogRefreshes += 1
                return WalletReviewCatalog(account: popupTestAccount())
            },
            makeSigner: { _ in
                signerCreations += 1
                return TestWalletSigner()
            },
            networkResolver: { _ in
                XCTFail("Message resolution must not look up a network")
                return .missing
            }
        )

        let result = await finalizer.attempt(consent: authorization)
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(errorCode, 4001)
        XCTAssertTrue(committed)
        XCTAssertEqual(catalogRefreshes, 1)
        XCTAssertEqual(signerCreations, 1)
        XCTAssertEqual(executions, 1)
    }

    func testNativeFinalizerKeepsApprovedWalletWhenAnotherWalletHasSameAddress() async throws {
        for transactionApproval in [false, true] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 812, provider: .ethereum,
                method: transactionApproval ? "signTransaction" : "signPersonalMessage"
            ), in: store)
            let transaction = popupReadyTransaction()
            let network = ResolvedEthereumNetwork(network: popupTransactionNetwork(), source: .custom)
            let approvedAccount = popupTestAccountDescriptor()
            let decision: DappApprovalDecision = transactionApproval
                ? .transaction(try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                    transaction, reviewedNetwork: network, approvedAccount: approvedAccount
                )))
                : .message(.init(approvedAccount: approvedAccount, solanaCluster: nil))
            let authorization = try await store.prepareNativeApproval(handle: snapshot.handle, decision: decision)
            let account = popupTestAccount()
            let replacementWalletID = "replacement-wallet"
            let catalog = WalletReviewCatalog(accounts: [
                SpecificWalletAccount(walletId: replacementWalletID, account: account),
                SpecificWalletAccount(walletId: approvedAccount.walletID, account: account),
            ])
            var signerCreations = 0
            var executions = 0
            let processor = CompactPopupProcessor(execute: { _, _, _, permit in
                executions += 1
                return approvedFailureForTesting(.userRejected, permit: permit)
            }) { _ in
                XCTFail("A matching address in another wallet must not remap the accepted intent")
                return .immediate(.failure(.internalError))
            }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: processor
                ),
                refreshWalletCatalog: { catalog },
                makeSigner: { operation in
                    XCTAssertEqual(operation.approvedAccount, approvedAccount)
                    signerCreations += 1
                    return TestWalletSigner()
                },
                networkResolver: popupApprovalNetwork
            )

            let result = await finalizer.attempt(consent: authorization)
            let errorCode = await store.completedErrorCode(handle: snapshot.handle)
            let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)

            XCTAssertEqual(result, .responseReady)
            XCTAssertEqual(errorCode, 4001)
            XCTAssertTrue(committed)
            XCTAssertEqual(signerCreations, 1)
            XCTAssertEqual(executions, 1)
        }
    }

    func testNativeFinalizerAddChainDoesNotCreateOrPassSigner() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 813, provider: .ethereum, method: "addEthereumChain"
        ), in: store)
        let authorization = try await store.prepareNativeApproval(handle: snapshot.handle, decision: .addEthereumChain)
        var executions = 0
        let processor = CompactPopupProcessor(execute: { request, approval, signer, permit in
            executions += 1
            XCTAssertNil(signer)
            XCTAssertNil(approval.signingAccount)
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _ in
            .approval(.addEthereumChain(AddEthereumChainAction(chainToAdd: popupTestNetwork())))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            makeSigner: { _ in
                XCTFail("Adding a chain must not create a signer")
                return TestWalletSigner()
            },
            networkResolver: popupApprovalNetwork
        )

        let result = await finalizer.attempt(consent: authorization)

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(executions, 1)
    }

    func testNativeFinalizerSharesCanonicalSelectionAndDisconnectRules() async throws {
        let account = WalletAccount(
            address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            coin: .ethereum,
            derivation: .default,
            derivationPath: popupTestAccount().derivationPath,
            publicKey: "",
            extendedPublicKey: ""
        )
        let specific = SpecificWalletAccount(walletId: "wallet", account: account)
        let identity = WalletAccountDescriptor(walletID: "wallet", account: account)
        let network = popupTransactionNetwork()
        let cases: [(name: String, accounts: [SpecificWalletAccount], selection: [WalletAccountDescriptor], selectedChainID: String?, network: EthereumNetwork?, allowed: Bool)] = [
            ("normalized identity", [specific], [identity], network.chainIdHexString, network, true),
            ("reviewed network fallback", [specific], [identity], nil, network, true),
            ("explicit network overrides review", [specific], [identity], "0x1", Networks.ethereum, true),
            ("missing explicit network does not fall back", [specific], [identity], "0x1", nil, false),
            ("ambiguous identity", [specific, specific], [identity], network.chainIdHexString, network, false),
            ("disconnect after selected network removal", [], [], network.chainIdHexString, nil, true),
            ("disconnect after reviewed network removal", [], [], nil, nil, true),
        ]
        for (index, scenario) in cases.enumerated() {
            let store = try makeStore()
            try await store.establishGrant(
                identity, configurationKey: "https://wallet.example", profileIdentifier: nil,
                chainID: network.chainIdHexString
            )
            let snapshot = try await enqueue(popupSnapshot(id: 800 + index, provider: .unknown), in: store)
            let decision = DappApprovalDecision.accountSelection(.init(
                accounts: scenario.selection,
                ethereumChainID: scenario.selectedChainID
            ))
            let authorization = try await store.prepareNativeApproval(handle: snapshot.handle, decision: decision)
            guard case .switchAccount(let reviewedSelection) = authorization.intent.action else {
                return XCTFail("Expected a manual account selection review")
            }
            XCTAssertEqual(reviewedSelection.network?.chainIdHexString, network.chainIdHexString, scenario.name)

            var executionCount = 0
            var catalogRefreshes = 0
            var networkLookups = 0
            let processor = CompactPopupProcessor(execute: { _, approval, _, permit in
                executionCount += 1
                guard case .accountSelection(_, let selection) = approval.kind else {
                    XCTFail("Expected the resolved account selection")
                    return .rollback
                }
                XCTAssertEqual(selection.network, scenario.network, scenario.name)
                return approvedFailureForTesting(.userRejected, permit: permit)
            }) { _ in
                .approval(.switchAccount(SelectAccountAction(
                    coinType: nil,
                    selectedAccounts: [],
                    initiallyConnectedProviders: [.ethereum],
                    network: network
                )))
            }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: processor
                ),
                refreshWalletCatalog: {
                    catalogRefreshes += 1
                    return WalletReviewCatalog(accounts: scenario.accounts)
                },
                networkResolver: { chainID in
                    networkLookups += 1
                    XCTAssertEqual(chainID, Int(hexString: scenario.selectedChainID ?? network.chainIdHexString), scenario.name)
                    return scenario.network.map { .resolved(ResolvedEthereumNetwork(network: $0, source: .custom)) } ?? .missing
                }
            )

            let result = await finalizer.attempt(consent: authorization)
            let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
            let errorCode = await store.completedErrorCode(handle: snapshot.handle)

            XCTAssertEqual(catalogRefreshes, 1, scenario.name)
            XCTAssertEqual(networkLookups, scenario.selection.isEmpty ? 0 : 1, scenario.name)
            XCTAssertEqual(result, .responseReady, scenario.name)
            XCTAssertEqual(executionCount, scenario.allowed ? 1 : 0, scenario.name)
            XCTAssertEqual(committed, scenario.allowed, scenario.name)
            XCTAssertEqual(errorCode, scenario.allowed ? 4001 : -32603, scenario.name)
        }
    }

    func testNativeFinalizerOverlappingAttemptPreservesExecutingConsent() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 815, provider: .ethereum, method: "signPersonalMessage"
        ), in: store)
        let consent = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .message(.init(approvedAccount: popupTestAccountDescriptor(), solanaCluster: nil))
        )
        let refreshStarted = expectation(description: "first attempt is refreshing the catalog")
        let refreshGate = makeGate()
        let signingAccess = PopupRecordingWalletSigningAccess()
        var refreshes = 0
        var signerCreations = 0
        var executions = 0
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                    executions += 1
                    guard let signer,
                          case .success(.response(let signed)) = await signer.sign(),
                          signed.executionID == permit.executionID else {
                        XCTFail("The original attempt must retain its signing authorization")
                        return .rollback
                    }
                    return .completed(ApprovedCompletion(signed: signed))
                })
            ),
            refreshWalletCatalog: {
                refreshes += 1
                refreshStarted.fulfill()
                await refreshGate.wait()
                return WalletReviewCatalog(account: popupTestAccount())
            },
            makeSigner: { operation in
                signerCreations += 1
                let session = WalletSigningSession(
                    signingAccess, authorization: operation.authorization, isCurrent: { true }
                )
                XCTAssertTrue(session.bind(operation: operation))
                return session
            },
            networkResolver: { _ in
                XCTFail("Message signing must not resolve a network")
                return .missing
            }
        )
        let first = Task { await finalizer.attempt(consent: consent) }
        await fulfillment(of: [refreshStarted], timeout: 1)
        XCTAssertTrue(consent.authorizationIsAvailable)

        let overlapping = await finalizer.attempt(consent: consent)

        XCTAssertEqual(overlapping, .pending)
        XCTAssertTrue(consent.authorizationIsAvailable)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(signerCreations, 0)
        XCTAssertEqual(executions, 0)
        XCTAssertTrue(signingAccess.operations.isEmpty)
        await refreshGate.open()
        let completed = await first.value
        let response = await store.response(handle: snapshot.handle)
        let events = await store.events()

        XCTAssertEqual(completed, .responseReady)
        XCTAssertNotNil(response?["result"] as? String)
        XCTAssertNil(response?["error"])
        XCTAssertFalse(consent.authorizationIsAvailable)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(signerCreations, 1)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(signingAccess.operations.count, 1)
        XCTAssertEqual(signingAccess.invalidationCount, 1)
        XCTAssertEqual(events, ["nativeClaim", "complete"])
    }

    func testNativeFinalizerTerminalAndMissingRequestsDoNoPrivilegedWork() async throws {
        for missing in [false, true] {
            let consentStore = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 816, provider: .ethereum, method: "signPersonalMessage"
            ), in: consentStore)
            let consent = try await consentStore.prepareNativeApproval(
                handle: snapshot.handle,
                decision: .message(.init(approvedAccount: popupTestAccountDescriptor(), solanaCluster: nil))
            )
            let store: ApprovalStoreTestFixture
            if missing {
                store = try makeStore()
            } else {
                store = consentStore
                let receipt = try XCTUnwrap(consent.nativeReceipt)
                let rejected = await store.bridge.rejectNativeDelivery(
                    handle: snapshot.handle, nativeDeliveryNonce: receipt.nativeDeliveryNonce,
                    runtimeInstanceIdentifier: receipt.owner.runtimeInstanceIdentifier
                )
                XCTAssertEqual(rejected, .persisted)
            }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                        XCTFail("A terminal or missing request cannot execute")
                        return .rollback
                    })
                ),
                refreshWalletCatalog: {
                    XCTFail("A terminal or missing request cannot refresh wallet authority")
                    return nil
                },
                makeSigner: { _ in
                    XCTFail("A terminal or missing request cannot create a signer")
                    return TestWalletSigner()
                },
                networkResolver: { _ in
                    XCTFail("A terminal or missing request cannot resolve a network")
                    return .missing
                }
            )
            let loadsBefore = await store.loadCount()
            XCTAssertTrue(consent.authorizationIsAvailable)

            let result = await finalizer.attempt(consent: consent)
            let loadsAfter = await store.loadCount()
            let events = await store.events()

            XCTAssertEqual(result, .responseReady)
            XCTAssertFalse(consent.authorizationIsAvailable)
            XCTAssertEqual(loadsAfter, loadsBefore)
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testNativeFinalizerExecutesMatchingDecisionExactlyOnce() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 130,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 4, solana: 2)
        ), in: store)
        let account = popupTestAccount()
        let access = WalletReviewCatalog(account: account)
        let signer = TestWalletSigner()
        var refreshes = 0
        var preparations = 0
        let network = popupTransactionNetwork()
        let decision = DappApprovalDecision.accountSelection(.init(
            accounts: [.init(walletID: "wallet", account: account)],
            ethereumChainID: network.chainIdHexString
        ))
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: decision
        )

        let processor = CompactPopupAccessProcessor(execute: { request, approval, walletAccess, permit in
            XCTAssertNil(walletAccess)
            XCTAssertNil(approval.signingAccount)
            guard case .accountSelection(_, let selection) = approval.kind else {
                XCTFail("Expected account selection")
                return approvedFailureForTesting(.internalError, permit: permit)
            }
            XCTAssertEqual(selection.accounts, access.orderedAccounts)
            XCTAssertEqual(selection.network, network)
            await store.record("resolve")
            return ApprovedCompletion.accountSelection(permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
        }) { request, walletAccess in
            preparations += 1
            XCTAssertEqual(walletAccess.identity, access.identity)
            return .approval(.selectAccount(SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: network
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor
            ),
            refreshWalletCatalog: {
                refreshes += 1
                guard refreshes == 1 else {
                    XCTFail("Preparation and selection must use the same catalog snapshot")
                    return WalletReviewCatalog(accounts: [])
                }
                return access
            },
            makeSigner: { _ in
                XCTFail("Account selection must not create a signer")
                return signer
            },
            networkResolver: { chainID in
                chainID == network.chainId ? .resolved(ResolvedEthereumNetwork(network: network, source: .custom)) : .missing
            }
        )

        let result = await finalizer.attempt(consent: authorization)
        let second = await finalizer.attempt(consent: authorization)
        let events = await store.events()
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(events, ["nativeClaim", "resolve", "complete"])
        XCTAssertTrue(committed)
    }

    func testNativeFinalizerExecutesDeliveredApprovalWithoutWorkerTrigger()
        async throws {
        let now = Date(timeIntervalSince1970: 2_050_000_000)
        let nativeClock = CompactExecutionClock(now)
        let store = try makeStore(clock: { nativeClock.now })
        let snapshot = try await enqueue(popupSnapshot(
            id: 138,
            provider: .ethereum, method: "signPersonalMessage",
            revisions: popupRevisions(ethereum: 4, solana: 2)
        ), in: store)
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .message(.init(approvedAccount: popupTestAccountDescriptor(), solanaCluster: nil))
        )

        nativeClock.now = now
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(),
                clock: { now }
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            networkResolver: popupApprovalNetwork
        )

        let result = await finalizer.attempt(consent: authorization)
        let second = await finalizer.attempt(consent: authorization)
        let events = await store.events()

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(second, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "complete"])
    }

    func testNativeFinalizerDistinguishesMissingAndChangedReviewedRPCEndpoint() async throws {
        for routeIsMissing in [false, true] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 139, provider: .ethereum, method: "signTransaction"
            ), in: store)
            let reviewedNetwork = ResolvedEthereumNetwork(network: popupTransactionNetwork(), source: .custom)
            let execution = try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                popupReadyTransaction(), reviewedNetwork: reviewedNetwork,
                approvedAccount: popupTestAccountDescriptor()
            ))
            let consent = try await store.prepareNativeApproval(
                handle: snapshot.handle, decision: .transaction(execution)
            )
            let changedNetwork = EthereumNetwork(
                chainId: reviewedNetwork.network.chainId, name: reviewedNetwork.network.name,
                symbol: reviewedNetwork.network.symbol,
                rpcEndpoint: .unauthenticated(URL(string: "https://other-rpc.example")!),
                isTestnet: reviewedNetwork.network.isTestnet,
                mightShowPrice: reviewedNetwork.network.mightShowPrice,
                explorer: reviewedNetwork.network.explorer
            )
            var catalogRefreshes = 0
            var transactionLookups = 0
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                        XCTFail("A missing or changed route must not execute")
                        return .rollback
                    })
                ),
                refreshWalletCatalog: {
                    catalogRefreshes += 1
                    return WalletReviewCatalog(account: popupTestAccount())
                },
                makeSigner: { _ in
                    XCTFail("A missing or changed route must not create a signer")
                    return TestWalletSigner()
                },
                networkResolver: { chainID in
                    transactionLookups += 1
                    XCTAssertEqual(chainID, reviewedNetwork.network.chainId)
                    return routeIsMissing ? .missing : .resolved(ResolvedEthereumNetwork(network: changedNetwork, source: .custom))
                }
            )
            let result = await finalizer.attempt(consent: consent)
            let error = await store.completedErrorCode(handle: snapshot.handle)
            let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
            let events = await store.events()
            XCTAssertEqual(result, .responseReady)
            XCTAssertEqual(error, routeIsMissing ? ProviderResponseError.internalErrorCode : 4100)
            XCTAssertEqual(catalogRefreshes, 1)
            XCTAssertEqual(transactionLookups, 1)
            XCTAssertEqual(events, ["nativeClaim", "complete"])
            XCTAssertFalse(committed)
        }
    }

    func testNativeFinalizerMissingSigningAccountPreservesProviderDenialAndSolanaRevocation() async throws {
        let cases: [(InpageProvider, String, Int)] = [
            (.ethereum, "signPersonalMessage", ProviderResponseError.internalErrorCode),
            (.ethereum, "signTransaction", 4100),
            (.solana, "signMessage", 4100),
        ]
        for (provider, method, expectedError) in cases {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(id: 815, provider: provider, method: method), in: store)
            let account = provider == .ethereum ? popupTestAccountDescriptor()
                : WalletAccountDescriptor(walletID: "wallet", account: popupSolanaTestAccount())
            let decision: DappApprovalDecision = method == "signTransaction"
                ? .transaction(try popupTransactionDecision())
                : .message(.init(approvedAccount: account, solanaCluster: nil))
            let consent = try await store.prepareNativeApproval(handle: snapshot.handle, decision: decision)
            guard case .snapshot(let before) = await store.bridge.configurationSnapshot(
                configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
            ) else { return XCTFail("Expected the reviewed grant") }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                        XCTFail("A removed account must not execute")
                        return .rollback
                    })
                ),
                refreshWalletCatalog: { WalletReviewCatalog(accounts: []) },
                makeSigner: { _ in
                    XCTFail("A removed account must not create a signer")
                    return TestWalletSigner()
                },
                networkResolver: popupApprovalNetwork
            )
            let result = await finalizer.attempt(consent: consent)
            let storedResponse = await store.response(handle: snapshot.handle)
            let response = try XCTUnwrap(storedResponse)
            XCTAssertEqual(result, .responseReady)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, expectedError)
            XCTAssertEqual(response["approvalCommitted"] as? Bool, false)
            guard case .snapshot(let after) = await store.bridge.configurationSnapshot(
                configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
            ) else { return XCTFail("Expected the final authority") }
            if provider == .solana {
                XCTAssertEqual(response["authorizationFailure"] as? Bool, true)
                XCTAssertEqual(before.solanaAccount, account)
                XCTAssertNil(after.solanaAccount)
                XCTAssertGreaterThan(after.version.revisions.solana, before.version.revisions.solana)
            } else {
                XCTAssertEqual(response["authorizationFailure"] as? Bool, false)
                XCTAssertEqual(after.ethereumAccount, before.ethereumAccount)
                XCTAssertEqual(after.version, before.version)
            }
        }
    }

    func testNativeFinalizerPreservesGrantWhenSigningAccountIsKnownButUnavailable() async throws {
        for provider in [InpageProvider.ethereum, .solana] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 816, provider: provider,
                method: provider == .ethereum ? "signPersonalMessage" : "signMessage"
            ), in: store)
            let account = provider == .ethereum ? popupTestAccountDescriptor()
                : WalletAccountDescriptor(walletID: "wallet", account: popupSolanaTestAccount())
            let consent = try await store.prepareNativeApproval(
                handle: snapshot.handle,
                decision: .message(.init(approvedAccount: account, solanaCluster: nil))
            )
            let available = WalletReviewCatalog(accounts: [account.specificAccount])
            let unavailable = WalletReviewCatalog(
                identity: available.identity, orderedAccounts: [], knownAccounts: [account]
            )
            guard case .snapshot(let before) = await store.bridge.configurationSnapshot(
                configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
            ) else { return XCTFail("Expected the reviewed grant") }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, _ in
                        XCTFail("An unavailable signing account must not execute")
                        return .rollback
                    })
                ),
                refreshWalletCatalog: { unavailable },
                makeSigner: { _ in
                    XCTFail("An unavailable signing account must not create a signer")
                    return TestWalletSigner()
                }
            )
            let result = await finalizer.attempt(consent: consent)
            let response = await store.response(handle: snapshot.handle)
            guard case .snapshot(let after) = await store.bridge.configurationSnapshot(
                configurationKey: snapshot.configurationKey, profileIdentifier: snapshot.handle.profileIdentifier
            ) else { return XCTFail("Expected the retained grant") }
            XCTAssertEqual(result, .reviewRequired)
            XCTAssertNil(response)
            XCTAssertEqual(after.version, before.version)
            XCTAssertEqual(after.ethereumAccount, before.ethereumAccount)
            XCTAssertEqual(after.solanaAccount, before.solanaAccount)
            XCTAssertFalse(consent.authorizationIsAvailable)
            let repeated = await finalizer.attempt(consent: consent)
            let events = await store.events()
            XCTAssertEqual(repeated, .reviewRequired)
            XCTAssertEqual(events, ["nativeClaim", "returnToReview"])
        }
    }

    func testNativeFinalizerRequiresFreshConsentAfterWalletRefreshFailure() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 136,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 4, solana: 2)
        ), in: store)
        let account = popupTestAccount()
        let network = popupTransactionNetwork()
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .accountSelection(.init(
                accounts: [.init(walletID: "wallet", account: account)],
                ethereumChainID: network.chainIdHexString
            ))
        )

        var refreshes = 0
        var preparations = 0
        var resolves = 0
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            guard case .accountSelection = approval.kind else {
                XCTFail("Expected account selection")
                return approvedFailureForTesting(.internalError, permit: permit)
            }
            resolves += 1
            await store.record("resolve")
            return ApprovedCompletion.accountSelection(permit: permit).map(ApprovedExecutionResult.completed) ?? .rollback
        }) { request in
            preparations += 1
            return .approval(.selectAccount(SelectAccountAction(
                coinType: .ethereum,
                selectedAccounts: [],
                initiallyConnectedProviders: [],
                network: network
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor
            ),
            refreshWalletCatalog: {
                refreshes += 1
                return refreshes == 1 ? nil : WalletReviewCatalog(account: account)
            },
            networkResolver: { chainID in
                chainID == network.chainId ? .resolved(ResolvedEthereumNetwork(network: network, source: .custom)) : .missing
            }
        )

        let first = await finalizer.attempt(consent: authorization)
        guard case .found(let retained) = await store.load(
            handle: snapshot.handle
        ) else { return XCTFail("Expected a request retained for fresh review") }
        let firstErrorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        let firstEvents = await store.events()

        XCTAssertEqual(first, .reviewRequired)
        XCTAssertEqual(retained.phase, .queued)
        XCTAssertEqual(retained.nativeDeliveryReceipt, authorization.nativeReceipt)
        XCTAssertNil(firstErrorCode)
        XCTAssertEqual(firstEvents, ["nativeClaim", "returnToReview"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(resolves, 0)
        XCTAssertFalse(authorization.authorizationIsAvailable)

        let repeated = await finalizer.attempt(consent: authorization)
        XCTAssertEqual(repeated, .reviewRequired)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(resolves, 0)

        let freshConsent = try await store.prepareNativeApproval(
            handle: snapshot.handle, decision: authorization.decision
        )
        XCTAssertFalse(freshConsent.sharesAuthorization(with: authorization))
        let retried = await finalizer.attempt(consent: freshConsent)
        let finalEvents = await store.events()
        let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)

        XCTAssertEqual(retried, .responseReady)
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(resolves, 1)
        XCTAssertEqual(finalEvents, ["nativeClaim", "returnToReview", "nativeClaim", "resolve", "complete"])
        XCTAssertTrue(committed)
    }

    func testNativeFinalizerNeverResendsAfterAmbiguousCheckpointFailure() async throws {
        for committedBeforeFailure in [false, true] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 179, provider: .ethereum, method: "signTransaction"
            ), in: store)
            let authorization = try await store.prepareNativeApproval(
                handle: snapshot.handle, decision: .transaction(try popupTransactionDecision())
            )
            await store.failNextCheckpoint(afterWriting: committedBeforeFailure)
            var sends = 0
            var executions = 0
            var signerCreations = 0
            let signingAccess = PopupRecordingWalletSigningAccess()
            let request = try XCTUnwrap(snapshot.request)
            _ = EthereumDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: request, transactionHash: try popupTransactionHashForTesting()
            )
            let sender = PopupBroadcastSender { _, _ in
                        sends += 1
                        return .failure(.rpc(.serverError(-32603, Strings.somethingWentWrong)))

        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { _, _, signer, permit in
                        executions += 1
                        guard let signer,
                              case .success(.broadcast(let signed)) = await signer.sign() else {
                            XCTFail("Expected signing before the checkpoint attempt")
                            return .rollback
                        }
                        return .broadcast(PreparedBroadcast(signed: signed))
                    }) { _ in
                        .approval(popupTransactionAction())
                    },
                broadcastSender: sender
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            makeSigner: { operation in
                    signerCreations += 1
                    XCTAssertEqual(operation.handle, snapshot.handle)
                    XCTAssertEqual(operation.approvedAccount, popupTestAccountDescriptor())
                    let session = WalletSigningSession(signingAccess, authorization: operation.authorization, isCurrent: { true })
                    XCTAssertTrue(session.bind(operation: operation))
                    return session
                },
            networkResolver: popupApprovalNetwork
        )
            let result = await finalizer.attempt(consent: authorization)
            XCTAssertEqual(result, .interruptionRequired)
            let storedResponse = await store.response(handle: snapshot.handle)
            let terminal = try XCTUnwrap(storedResponse)
            let error = try XCTUnwrap(terminal["error"] as? [String: Any])
            XCTAssertEqual(error["message"] as? String, committedBeforeFailure
                ? Strings.transactionSubmissionStatusUnknown : Strings.approvalInterrupted)
            let repeated = await finalizer.attempt(consent: authorization)
            XCTAssertEqual(repeated, .responseReady)
            XCTAssertEqual(executions, 1)
            XCTAssertEqual(signerCreations, 1)
            XCTAssertEqual(signingAccess.operations.count, 1)
            XCTAssertEqual(signingAccess.invalidationCount, 1)
            XCTAssertEqual(sends, 0)
        }
    }

    func testCanceledNativeExecutionCannotCheckpointOrBroadcast() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 181, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle, decision: .transaction(try popupTransactionDecision())
        )
        let started = expectation(description: "signing started")
        let gate = makeGate()
        var sends = 0
        let sender = PopupBroadcastSender { _, _ in sends += 1; return .failure(.rpc(.serverError(-32603, Strings.somethingWentWrong)))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor(execute: { request, _, signer, permit in
                    let prepared = await popupPreparedBroadcast(permit: permit, signer: signer)
                    guard case .broadcast = prepared else {
                        XCTFail("Expected a signed broadcast before cancellation")
                        return .rollback
                    }
                    started.fulfill()
                    await gate.wait()
                    return prepared
                }) { _ in
                    .approval(popupTransactionAction())
                },
                broadcastSender: sender
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            makeSigner: { makeWalletSignerForTesting($0) },
            networkResolver: popupApprovalNetwork
        )
        let task = Task { await finalizer.attempt(consent: authorization) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.open()
        let result = await task.value
        XCTAssertEqual(result, .interruptionRequired)
        XCTAssertEqual(sends, 0)
        let events = await store.events()
        XCTAssertFalse(events.contains("checkpoint"))
        let repeated = await finalizer.attempt(consent: authorization)
        XCTAssertEqual(repeated, .responseReady)
    }

    func testNativeFinalizerFailureCannotExecuteAgain() async throws {
        for failure in ["authorization", "completion"] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 180, provider: .ethereum, method: "signPersonalMessage"
            ), in: store)
            let authorization = try await store.prepareNativeApproval(
                handle: snapshot.handle, decision: .message(.init(approvedAccount: popupTestAccountDescriptor(), solanaCluster: nil))
            )
            if failure == "authorization" { await store.failNextAuthorization() }
            else { await store.failNextCompletion() }
            var executions = 0
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { request, _, _, permit in
                        executions += 1
                        return approvedFailureForTesting(.userRejected, permit: permit)
                    }) { _ in
                        .approval(.approveMessage(SignMessageAction(
                            subject: .signPersonalMessage, walletId: "wallet", account: popupTestAccount(),
                            meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
                        )))
                    }
                ),
                refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
                networkResolver: popupApprovalNetwork
            )
            let result = await finalizer.attempt(consent: authorization)
            XCTAssertEqual(result, .interruptionRequired)
            let repeated = await finalizer.attempt(consent: authorization)
            XCTAssertEqual(repeated, .responseReady)
            XCTAssertEqual(executions, failure == "authorization" ? 0 : 1)
        }
    }

    func testNativeFinalizerRejectsRevokedAuthorityBeforeResolve() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 131,
            provider: .ethereum, method: "signPersonalMessage",
            revisions: popupRevisions(ethereum: 3, solana: 8)
        ), in: store)
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .message(.init(approvedAccount: popupTestAccountDescriptor(), solanaCluster: nil))
        )

        _ = try XCTUnwrap(snapshot.request)
        let processor = CompactPopupProcessor { _ in
            XCTFail("Revision mismatch must not rematerialize or resolve")
            return .immediate(.failure(.internalError))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            networkResolver: popupApprovalNetwork
        )

        await store.setAuthorityCurrent(false)
        let result = await finalizer.attempt(consent: authorization)
        XCTAssertEqual(result, .interruptionRequired)
        let events = await store.events()
        XCTAssertTrue(events.contains("nativeClaim"))
        XCTAssertFalse(events.contains("complete"))
    }

    func testNativeFinalizerEnforcesTransactionDecisionCutoff() async throws {
        let methods: [(InpageProvider, String)] = [
            (.ethereum, "signTransaction"),
            (.solana, "signTransaction"),
            (.solana, "signAllTransactions"),
            (.solana, "signAndSendTransaction"),
        ]
        let approvedAt = Date(timeIntervalSince1970: 2_100_000_000)
        let limit = ExtensionBridge.maximumTransactionDecisionAge
        for (provider, method) in methods {
            for age in [limit - 0.001, limit, limit + 1] {
                let label = "\(provider.rawValue) \(method) at \(age) seconds"
                let nativeClock = CompactExecutionClock(approvedAt)
                let store = try makeStore(clock: { nativeClock.now })
                let account = provider == .ethereum ? popupTestAccount() : popupSolanaTestAccount()
                let descriptor = WalletAccountDescriptor(walletID: "wallet", account: account)
                let snapshot = try await enqueue(popupSnapshot(
                    id: 132, provider: provider, method: method,
                    revisions: popupRevisions(ethereum: 2, solana: 2)
                ), in: store)
                let decision: DappApprovalDecision
                if provider == .ethereum {
                    decision = .transaction(try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                        popupReadyTransaction(),
                        reviewedNetwork: .init(network: popupTransactionNetwork(), source: .custom),
                        approvedAccount: descriptor
                    )))
                } else {
                    decision = .message(.init(
                        approvedAccount: descriptor,
                        solanaCluster: method == "signAndSendTransaction" ? .devnet : nil
                    ))
                }
                let authorization = try await store.prepareNativeApproval(
                    handle: snapshot.handle, decision: decision, approvedAt: approvedAt
                )
                nativeClock.now = approvedAt.addingTimeInterval(age)
                var catalogRefreshes = 0
                var signerCreations = 0
                var executions = 0
                let finalizer = NativeApprovalFinalizer(
                    store: store,
                    executionEnvironment: .init(
                        requestProcessor: CompactPopupProcessor(execute: { _, _, _, permit in
                            executions += 1
                            return approvedFailureForTesting(.userRejected, permit: permit)
                        }, handler: { _ in
                            XCTFail("Native finalization must use the original reviewed payload")
                            return .immediate(.failure(.internalError))
                        }),
                        clock: { nativeClock.now }
                    ),
                    refreshWalletCatalog: {
                        catalogRefreshes += 1
                        return WalletReviewCatalog(account: account)
                    },
                    makeSigner: { operation in
                        signerCreations += 1
                        XCTAssertEqual(operation.deadline, approvedAt.addingTimeInterval(limit), label)
                        return TestWalletSigner()
                    },
                    networkResolver: popupApprovalNetwork
                )

                let result = await finalizer.attempt(consent: authorization)
                let errorCode = await store.completedErrorCode(handle: snapshot.handle)
                let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
                let fresh = age < limit
                XCTAssertEqual(result, .responseReady, label)
                XCTAssertEqual(catalogRefreshes, fresh ? 1 : 0, label)
                XCTAssertEqual(signerCreations, fresh ? 1 : 0, label)
                XCTAssertEqual(executions, fresh ? 1 : 0, label)
                XCTAssertEqual(errorCode, fresh ? 4001 : 4100, label)
                XCTAssertEqual(committed, fresh, label)
                if !fresh {
                    let events = await store.events()
                    XCTAssertEqual(events, ["nativeClaim", "complete"], label)
                }
            }
        }
    }

    func testNativeFinalizerRejectsFutureTransactionDecisionBeforeResolve() async throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let nativeClock = CompactExecutionClock(now)
        let store = try makeStore(clock: { nativeClock.now })
        let snapshot = try await enqueue(popupSnapshot(
            id: 133,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        ), in: store)
        let execution = try XCTUnwrap(
            DappApprovalDecision.TransactionExecution(
                popupReadyTransaction(),
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                ),
                approvedAccount: popupTestAccountDescriptor()
            )
        )
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .transaction(execution),
            approvedAt: now
        )

        nativeClock.now = now.addingTimeInterval(-1)
        _ = try XCTUnwrap(snapshot.request)
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor { _ in
                    XCTFail("Future transaction decision must not be prepared")
                    return .immediate(.failure(.internalError))
                },
                clock: { nativeClock.now }
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            networkResolver: popupApprovalNetwork
        )

        let result = await finalizer.attempt(consent: authorization)
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .interruptionRequired)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(errorCode)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRejectsFutureSolanaTransactionDecisions() async throws {
        let methods = [
            "signTransaction",
            "signAllTransactions",
            "signAndSendTransaction",
        ]
        for (offset, method) in methods.enumerated() {
            let now = Date(timeIntervalSince1970: 2_160_000_000)
            let nativeClock = CompactExecutionClock(now)
            let store = try makeStore(clock: { nativeClock.now })
            let snapshot = try await enqueue(popupSnapshot(
                id: 150 + offset,
                provider: .solana,
                method: method,
                revisions: popupRevisions(ethereum: 1, solana: 2)
            ), in: store)
            let authorization = try await store.prepareNativeApproval(
                handle: snapshot.handle,
                decision: .message(.init(approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: popupSolanaTestAccount()), solanaCluster: method == "signAndSendTransaction" ? .devnet : nil)),
                approvedAt: now
            )

            nativeClock.now = now.addingTimeInterval(-1)
            _ = try XCTUnwrap(snapshot.request)
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor { _ in
                        XCTFail("Future \(method) decision must not be prepared")
                        return .immediate(.failure(.internalError))
                    },
                    clock: { nativeClock.now }
                ),
                refreshWalletCatalog: { WalletReviewCatalog(account: popupSolanaTestAccount()) },
                networkResolver: popupApprovalNetwork
            )

        let result = await finalizer.attempt(consent: authorization)
            let errorCode = await store.completedErrorCode(
                handle: snapshot.handle
            )
            XCTAssertEqual(result, .interruptionRequired, method)
            XCTAssertNil(errorCode, method)
            let events = await store.events()
            XCTAssertTrue(events.isEmpty, method)
        }
    }

    func testNativeFinalizerDoesNotAgeMessageSigning() async throws {
        let approvedAt = Date(timeIntervalSince1970: 2_170_000_000)
        let methods: [(InpageProvider, String)] = [
            (.ethereum, "signPersonalMessage"),
            (.solana, "signMessage"),
        ]
        for (provider, method) in methods {
            let nativeClock = CompactExecutionClock(approvedAt)
            let store = try makeStore(clock: { nativeClock.now })
            let account = provider == .ethereum ? popupTestAccount() : popupSolanaTestAccount()
            let snapshot = try await enqueue(popupSnapshot(
                id: 160, provider: provider, method: method,
                revisions: popupRevisions(ethereum: 2, solana: 2)
            ), in: store)
            let authorization = try await store.prepareNativeApproval(
                handle: snapshot.handle,
                decision: .message(.init(
                    approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: account),
                    solanaCluster: nil
                )),
                approvedAt: approvedAt
            )
            nativeClock.now = approvedAt.addingTimeInterval(ExtensionBridge.maximumTransactionDecisionAge + 1)
            var executions = 0
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: CompactPopupProcessor(execute: { _, _, _, permit in
                        executions += 1
                        return approvedFailureForTesting(.userRejected, permit: permit)
                    }, handler: { _ in
                        XCTFail("Native finalization must use the original reviewed payload")
                        return .immediate(.failure(.internalError))
                    }),
                    clock: { nativeClock.now }
                ),
                refreshWalletCatalog: { WalletReviewCatalog(account: account) },
                makeSigner: { _ in TestWalletSigner() },
                networkResolver: popupApprovalNetwork
            )

            let result = await finalizer.attempt(consent: authorization)
            let committed = await store.completedApprovalWasCommitted(handle: snapshot.handle)
            let errorCode = await store.completedErrorCode(handle: snapshot.handle)
            XCTAssertEqual(result, .responseReady, method)
            XCTAssertEqual(executions, 1, method)
            XCTAssertEqual(errorCode, 4001, method)
            XCTAssertTrue(committed, method)
        }
    }

    func testNativeFinalizerRechecksTransactionAgeAfterRefreshingFacts() async throws {
        let nativeClock = CompactExecutionClock(Date(timeIntervalSince1970: 2_200_000_000))
        let store = try makeStore(clock: { nativeClock.now })
        let snapshot = try await enqueue(popupSnapshot(
            id: 134,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        ), in: store)
        let transaction = popupReadyTransaction()
        let execution = try XCTUnwrap(
            DappApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                ),
                approvedAccount: popupTestAccountDescriptor()
            )
        )
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .transaction(execution),
            approvedAt: nativeClock.now
        )

        var resolveCount = 0
        let network = popupTransactionNetwork()
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _ in
            return .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(network: network, source: .custom),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor,
                clock: { nativeClock.now }
            ),
            refreshWalletCatalog: {
                nativeClock.now = nativeClock.now.addingTimeInterval(ExtensionBridge.maximumTransactionDecisionAge + 1)
                return WalletReviewCatalog(account: popupTestAccount())
            },
            makeSigner: { _ in
                XCTFail("An expired approval must not issue a signer")
                return TestWalletSigner()
            },
            networkResolver: popupApprovalNetwork
        )

        let result = await finalizer.attempt(consent: authorization)
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRechecksTransactionAgeAfterClaim() async throws {
        let nativeClock = CompactExecutionClock(Date(timeIntervalSince1970: 2_300_000_000))
        let store = try makeStore(clock: { nativeClock.now })
        let snapshot = try await enqueue(popupSnapshot(
            id: 135,
            provider: .ethereum,
            method: "signTransaction",
            revisions: popupRevisions(ethereum: 2, solana: 1)
        ), in: store)
        let transaction = popupReadyTransaction()
        let execution = try XCTUnwrap(
            DappApprovalDecision.TransactionExecution(
                transaction,
                reviewedNetwork: .init(
                    network: popupTransactionNetwork(),
                    source: .custom
                ),
                approvedAccount: popupTestAccountDescriptor()
            )
        )
        let authorization = try await store.prepareNativeApproval(
            handle: snapshot.handle,
            decision: .transaction(execution),
            approvedAt: nativeClock.now
        )

        var resolveCount = 0
        let network = popupTransactionNetwork()
        let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
            resolveCount += 1
            return approvedFailureForTesting(.userRejected, permit: permit)
        }) { _ in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: .init(network: network, source: .custom),
                walletId: "wallet",
                account: popupTestAccount()
            )))
        }
        await store.observeNextClaim { _ in
            nativeClock.now = nativeClock.now.addingTimeInterval(
                ExtensionBridge.maximumTransactionDecisionAge + 1
            )
        }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor,
                clock: { nativeClock.now }
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            makeSigner: { _ in
                XCTFail("An expired approval must not issue a signer")
                return TestWalletSigner()
            },
            networkResolver: popupApprovalNetwork
        )

        let result = await finalizer.attempt(consent: authorization)
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        let committed = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(events, ["nativeClaim", "complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(resolveCount, 0)
        XCTAssertFalse(committed)
    }

    func testNativeFinalizerRechecksSolanaTransactionAgeBeforeExecution() async throws {
        for advancesAtClaim in [false, true] {
            let nativeClock = CompactExecutionClock(Date(timeIntervalSince1970: 2_350_000_000))
            let store = try makeStore(clock: { nativeClock.now })
            let snapshot = try await enqueue(popupSnapshot(
                id: advancesAtClaim ? 171 : 170,
                provider: .solana,
                method: "signTransaction",
                revisions: popupRevisions(ethereum: 1, solana: 2)
            ), in: store)
            let authorization = try await store.prepareNativeApproval(
                handle: snapshot.handle,
                decision: .message(.init(approvedAccount: WalletAccountDescriptor(walletID: "wallet", account: popupSolanaTestAccount()), solanaCluster: nil)),
                approvedAt: nativeClock.now
            )

                var resolveCount = 0
            let processor = CompactPopupProcessor(execute: { request, approval, walletAccess, permit in
                resolveCount += 1
                return approvedFailureForTesting(.userRejected, permit: permit)
            }) { _ in
                XCTFail("Native finalization must not prepare a second payload")
                return .immediate(.failure(.internalError))
            }
            if advancesAtClaim {
                await store.observeNextClaim { _ in
                    nativeClock.now = nativeClock.now.addingTimeInterval(
                        ExtensionBridge.maximumTransactionDecisionAge + 1
                    )
                }
            }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: processor,
                    clock: { nativeClock.now }
                ),
                refreshWalletCatalog: {
                    if !advancesAtClaim {
                        nativeClock.now = nativeClock.now.addingTimeInterval(ExtensionBridge.maximumTransactionDecisionAge + 1)
                    }
                    return WalletReviewCatalog(account: popupSolanaTestAccount())
                },
                makeSigner: { _ in
                    XCTFail("An expired approval must not issue a signer")
                    return TestWalletSigner()
                },
                networkResolver: popupApprovalNetwork
            )

        let result = await finalizer.attempt(consent: authorization)
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

    func testNativeAgentConfirmationUsesProcessStartWhenLaunchDateIsNil() async throws {
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

        let confirmed = NativeAgentLauncher(dependencies: launcherTestDependencies(
            validate: { _ in
                XCTFail("Confirmation must not validate code")
                return false
            },
            helpers: { [validRuntime] },
            identity: { _ in identity }
        )).isConfirmed(
            try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL)),
            deadline: UInt64.max
        )
        XCTAssertTrue(confirmed)
        let replaced = NativeAgentLauncher(dependencies: launcherTestDependencies(
            validate: { _ in
                XCTFail("A replaced process must not reach code verification")
                return true
            },
            helpers: { [reusedPIDRuntime] },
            identity: { _ in identity }
        )).isConfirmed(
            try XCTUnwrap(NativeAgentLauncher.ExpectedRuntime(url: bundleURL)),
            deadline: UInt64.max
        )
        XCTAssertFalse(replaced)
    }

    func testNativeAgentQuitDoesNotTargetReusedProcessIdentifier() {
        let capturedStartDate = Date(timeIntervalSince1970: 1_000)
        var targetedProcessIdentifier: Int32?

        XCTAssertTrue(NativeAgentRuntime.requestExactReceiptOwnerQuit(
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

        XCTAssertTrue(NativeAgentRuntime.requestExactReceiptOwnerQuit(
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

        XCTAssertFalse(NativeAgentRuntime.requestExactReceiptOwnerQuit(
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

        XCTAssertFalse(NativeAgentRuntime.requestExactReceiptOwnerQuit(
            processIdentifier: 8_114,
            capturedStartDate: capturedStartDate,
            runningProcessStartDate: { _ in nil },
            sendQuitEvent: { processIdentifier in
                targetedProcessIdentifier = processIdentifier
                return true
            }
        ))
        XCTAssertTrue(NativeAgentRuntime.runtimeProcessIsRunning(
            processIdentifier: 8_114,
            capturedStartDate: capturedStartDate,
            isTerminated: false,
            runningProcessStartDate: { _ in nil }
        ))
        XCTAssertNil(targetedProcessIdentifier)
    }

    func testNativeAgentTreatsUnidentifiedLiveProcessAsRunning() {
        XCTAssertTrue(NativeAgentRuntime.runtimeProcessIsRunning(
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

    func testNativeCoordinatorOwnsFailedAttemptInterruption() async throws {
        for failure in ["authorization", "completion", "checkpointBefore", "checkpointAfter"] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 210, provider: .ethereum, method: "signTransaction"
            ), in: store)
            let request = try XCTUnwrap(snapshot.request)
            let action = nativeIntegrationAction()
            var executions = 0
            var sends = 0
            let recovery = EthereumDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: request, transactionHash: try popupTransactionHashForTesting()
            )
            let sender = PopupBroadcastSender { _, _ in
                        sends += 1
                        return .failure(.rpc(.serverError(-32603, Strings.somethingWentWrong)))

        }
        let processor = CompactPopupProcessor(execute: { request, _, signer, permit in
                executions += 1
                if failure.hasPrefix("checkpoint") {
                    return await popupPreparedBroadcast(permit: permit, signer: signer)
                }
                return approvedFailureForTesting(.userRejected, permit: permit)
            }) { _ in .approval(action) }
            if failure == "authorization" { await store.failNextAuthorization() }
            if failure == "completion" { await store.failNextCompletion() }
            if failure.hasPrefix("checkpoint") {
                await store.failNextCheckpoint(afterWriting: failure == "checkpointAfter")
            }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: processor,
                    broadcastSender: sender
                ),
                refreshWalletCatalog: {
                    WalletReviewCatalog(account: popupTestAccount())
                },
                makeSigner: { makeWalletSignerForTesting($0) },
                networkResolver: popupApprovalNetwork
            )
            var attempts = 0
            let coordinator = makeNativeIntegrationCoordinator(store: store, snapshot: snapshot, action: action) {
                authorization in
                attempts += 1
                let loads = await store.loadCount()
                let result = await finalizer.attempt(consent: authorization)
                let laterLoads = await store.loadCount()
                XCTAssertEqual(loads, laterLoads, "The finalizer must claim directly without a preliminary load")
                XCTAssertEqual(result, .interruptionRequired)
                return result
            }
            coordinator.start(nativeDeliveryOwner: popupNativeDeliveryOwner())
            try await waitForCondition { coordinator.isFinished }
            let observer = await store.makeObserverBridge { _, _ in
                XCTFail("The coordinator must persist interruption before finishing")
                throw CocoaError(.fileWriteNoPermission)
            }
            let response = await observer.prepareResponseDelivery(
                id: snapshot.handle.id, configurationKey: snapshot.configurationKey,
                requestToken: snapshot.handle.requestToken, profileIdentifier: nil
            )
            guard case .response(let json) = response,
                  let terminal = ResponseToExtension(json: json["response"] as? [String: Any] ?? [:]) else {
                return XCTFail("Expected a terminal response for \(failure)")
            }
            if failure == "checkpointAfter" {
                XCTAssertEqual(terminal.json as NSDictionary, recovery.markingApprovalCommitted().json as NSDictionary)
                guard case .finished? = coordinator.currentPresentation?.presentation else {
                    return XCTFail("A persisted broadcast checkpoint must remain recoverable")
                }
            } else {
                XCTAssertEqual(terminal.json as NSDictionary, request.response(error: .approvalInterrupted).json as NSDictionary)
                guard case .interrupted? = coordinator.currentPresentation?.presentation else {
                    return XCTFail("Expected the interrupted presentation")
                }
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(executions, failure == "authorization" ? 0 : 1)
            XCTAssertEqual(sends, 0)
        }
    }

    func testNativeCoordinatorRequiresFreshReviewAfterDeliveryOwnerIsCleared() async throws {
        let store = try makeStore()
        let snapshot = try await enqueue(popupSnapshot(
            id: 211, provider: .ethereum, method: "signTransaction"
        ), in: store)
        let action = nativeIntegrationAction()
        let processor = CompactPopupProcessor(execute: { request, _, _, permit in
            XCTFail("A cleared receipt cannot authorize execution")
            return approvedFailureForTesting(.internalError, permit: permit)
        }) { _ in .approval(action) }
        let finalizer = NativeApprovalFinalizer(
            store: store,
            executionEnvironment: .init(
                requestProcessor: processor
            ),
            refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
            networkResolver: popupApprovalNetwork
        )
        let observer = await store.makeObserverBridge()
        let coordinator = makeNativeIntegrationCoordinator(store: store, snapshot: snapshot, action: action) {
            authorization in
            let cleared = await observer.clearNativeDeliveryReceipt(
                handle: authorization.binding.handle, nativeDeliveryNonce: authorization.nativeReceipt!.nativeDeliveryNonce,
                runtimeInstanceIdentifier: authorization.nativeReceipt!.owner.runtimeInstanceIdentifier
            )
            XCTAssertEqual(cleared, .persisted)
            let result = await finalizer.attempt(consent: authorization)
            XCTAssertEqual(result, .interruptionRequired)
            return result
        }
        coordinator.start(nativeDeliveryOwner: popupNativeDeliveryOwner())
        try await waitForCondition { coordinator.isFinished }
        let events = await store.events()
        XCTAssertTrue(events.isEmpty)
        let response = await store.response(handle: snapshot.handle)
        XCTAssertNil(response)
        let retained = try await store.snapshot(handle: snapshot.handle)
        guard case .queued(_, .unowned) = retained.state else {
            return XCTFail("A cleared delivery must require fresh review")
        }
    }

    func testReleasedNativeCoordinatorCannotReplayFailedClaimOrCheckpoint() async throws {
        for failure in ["authorization", "checkpointBefore", "checkpointAfter"] {
            let store = try makeStore()
            let snapshot = try await enqueue(popupSnapshot(
                id: 212, provider: .ethereum, method: "signTransaction"
            ), in: store)
            let request = try XCTUnwrap(snapshot.request)
            let action = nativeIntegrationAction()
            let recovery = EthereumDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: request, transactionHash: try popupTransactionHashForTesting()
            )
            var executions = 0
            var sends = 0
            let sender = PopupBroadcastSender { _, _ in
                    sends += 1
                    return .failure(.rpc(.serverError(-32603, Strings.somethingWentWrong)))

        }
        let processor = CompactPopupProcessor(execute: { request, _, signer, permit in
                executions += 1
                return await popupPreparedBroadcast(permit: permit, signer: signer)
            }) { _ in .approval(action) }
            let finalizer = NativeApprovalFinalizer(
                store: store,
                executionEnvironment: .init(
                    requestProcessor: processor,
                    broadcastSender: sender
                ),
                refreshWalletCatalog: { WalletReviewCatalog(account: popupTestAccount()) },
                makeSigner: { makeWalletSignerForTesting($0) },
                networkResolver: popupApprovalNetwork
            )
            var coordinator: NativeApprovalCoordinator?
            weak var weakCoordinator: NativeApprovalCoordinator?
            if failure == "authorization" {
                await store.failNextAuthorization()
                await store.setAuthorizationHook { coordinator = nil }
            } else {
                await store.failNextCheckpoint(afterWriting: failure == "checkpointAfter")
            }
            let completed = expectation(description: "attempt completed")
            let gate = makeGate()
            var captured: ReviewConsent?
            var presentations = 0
            coordinator = makeNativeIntegrationCoordinator(
                store: store, snapshot: snapshot, action: action,
                onPresentation: { presentations += 1 }
            ) { authorization in
                captured = authorization
                let result = await finalizer.attempt(consent: authorization)
                XCTAssertEqual(result, .interruptionRequired)
                completed.fulfill()
                await gate.wait()
                return result
            }
            weakCoordinator = coordinator
            coordinator?.start(nativeDeliveryOwner: popupNativeDeliveryOwner())
            await fulfillment(of: [completed], timeout: 2)
            if failure == "authorization" { XCTAssertNil(weakCoordinator) }
            coordinator = nil
            XCTAssertNil(weakCoordinator)
            let presentationCount = presentations
            let observer = await store.makeObserverBridge()
            let response = await observer.prepareResponseDelivery(
                id: snapshot.handle.id, configurationKey: snapshot.configurationKey,
                requestToken: snapshot.handle.requestToken, profileIdentifier: nil
            )
            guard case .response(let json) = response else {
                return XCTFail("Expected orphaned execution recovery")
            }
            let expected = failure == "checkpointAfter"
                ? recovery.markingApprovalCommitted() : request.response(error: .approvalInterrupted)
            XCTAssertEqual(json["response"] as? NSDictionary, expected.json as NSDictionary)
            let authorization = try XCTUnwrap(captured)
            let repeated = await finalizer.attempt(consent: authorization)
            XCTAssertEqual(repeated, .responseReady)
            await gate.open()
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(presentations, presentationCount)
            XCTAssertEqual(executions, failure == "authorization" ? 0 : 1)
            XCTAssertEqual(sends, 0)
            await store.setAuthorizationHook {}
        }
    }

    private func nativeIntegrationAction() -> DappRequestAction {
        popupTransactionAction()
    }

    private func makeNativeIntegrationCoordinator(
        store: ApprovalStoreTestFixture,
        snapshot: ExtensionBridge.Snapshot,
        action: DappRequestAction,
        onPresentation: @escaping () -> Void = {},
        attempt: @escaping @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult
    ) -> NativeApprovalCoordinator {
        let coordinator = NativeApprovalCoordinator(
            handle: snapshot.handle, nativeDeliveryNonce: snapshot.nativeDeliveryNonce,
            store: store.bridge,
            environment: .init(
                now: Date.init, wait: { _ in await Task.yield() },
                prepareWithoutWallets: { binding in preparationForTesting(binding: binding, action: action) },
                attemptNativeDecision: attempt
            )
        )
        coordinator.onEvent = { [weak coordinator] (event: NativeApprovalCoordinator.Event) in
            switch event {
            case .authenticationRequired:
                coordinator?.resumeAfterAuthentication()
            case .presentationChanged:
                onPresentation()
                if case .approval? = coordinator?.currentPresentation?.presentation {
                    coordinator?.approveTransaction(
                        popupReadyTransaction(),
                        reviewedNetwork: .init(network: popupTransactionNetwork(), source: .custom)
                    )
                }
            }
        }
        return coordinator
    }

    func testNativeAgentLaunchConfigurationIsPrivateAndCopyIsolated() {
        let configuration = NativeAgentRuntime.applicationLaunchConfiguration()

        XCTAssertTrue(configuration.activates)
        XCTAssertFalse(configuration.addsToRecentItems)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
        XCTAssertFalse(configuration.createsNewApplicationInstance)
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

    #endif

    private func makeGate() -> CompactPopupGate {
        let gate = CompactPopupGate()
        addTeardownBlock { await gate.open() }
        return gate
    }

    private struct ExecutionSetup {
        let snapshot: ExtensionBridge.Snapshot
        let claim: ExtensionBridge.ApprovalClaim
        let consent: ReviewConsent
        let approval: ResolvedDappApproval
    }

    private func execute(
        _ executor: DurableApprovalExecutor,
        setup: ExecutionSetup,
        signing: DurableApprovalExecutor.SigningAccess
    ) async -> DurableApprovalExecutor.Result {
        await executor.execute(claim: setup.claim, prepare: { _ in
            .ready(consent: setup.consent, signing: signing)
        }, resolve: { _ in .approved(setup.approval) })
    }

    private func makeExecutionSetup(
        store: ApprovalStoreTestFixture,
        id: Int,
        native: Bool = false,
        signing: Bool = true
    ) async throws -> ExecutionSetup {
        let snapshot = try await enqueue(popupSnapshot(
            id: id, provider: .ethereum,
            method: signing ? "signTransaction" : "addEthereumChain"
        ), in: store)
        let action: DappRequestAction
        let decision: DappApprovalDecision
        if signing {
            let network = ResolvedEthereumNetwork(network: popupTransactionNetwork(), source: .custom)
            action = .approveTransaction(.init(
                transaction: popupReadyTransaction(), resolvedNetwork: network,
                walletId: "wallet", account: popupTestAccount()
            ))
            decision = .transaction(try XCTUnwrap(DappApprovalDecision.TransactionExecution(
                popupReadyTransaction(), reviewedNetwork: network,
                approvedAccount: popupTestAccountDescriptor()
            )))
        } else {
            action = .addEthereumChain(.init(chainToAdd: popupTestNetwork()))
            decision = .addEthereumChain
        }
        let claim: ExtensionBridge.ApprovalClaim
        let consent: ReviewConsent
        if native {
            consent = try await store.prepareNativeApproval(
                handle: snapshot.handle, decision: decision, action: action
            )
            guard case .claimed(let value) = await store.claimNativeExecution(consent: consent) else { throw CocoaError(.fileWriteUnknown) }
            claim = value
        } else {
            consent = try reviewConsentForTesting(
                snapshot: snapshot, action: action, decision: decision,
                approvedAt: snapshot.createdAt
            )
            guard case .claimed(let value) = await store.claim(handle: snapshot.handle) else {
                throw CocoaError(.fileWriteUnknown)
            }
            claim = value
        }
        let approval = try consent.resolve(
            context: approvalResolutionContextForTesting(
                action: consent.intent.action,
                decision: consent.decision,
                accounts: reviewCatalogForTesting(action: action).orderedAccounts
            )
        ).get()
        return ExecutionSetup(snapshot: snapshot, claim: claim, consent: consent, approval: approval)
    }

    private func makeStore(
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> ApprovalStoreTestFixture {
        let store = try ApprovalStoreTestFixture(clock: clock)
        addTeardownBlock { try await store.cleanup() }
        return store
    }

    private func enqueue(
        _ template: ExtensionBridge.Snapshot,
        in store: ApprovalStoreTestFixture
    ) async throws -> ExtensionBridge.Snapshot {
        let request = try XCTUnwrap(template.request)
        let body: [String: Any]
        switch request.body {
        case .ethereum(let value):
            var json: [String: Any] = ["address": value.address]
            if let chain = value.currentChainId { json["chainId"] = String.hex(chain, withPrefix: true) }
            if let parameters = value.parameters { json["object"] = parameters }
            body = json
        case .solana(let value):
            var parameters = [String: Any]()
            parameters["message"] = value.message
            parameters["messages"] = value.messages
            parameters["transaction"] = value.transaction
            parameters["options"] = value.sendOptions
            parameters["messageEncoding"] = value.signMessageEncoding == .utf8 ? "utf8" : "hex"
            if value.displayHex { parameters["display"] = "hex" }
            body = ["publicKey": value.publicKey, "object": ["params": parameters]]
        case .unknown(let value):
            body = ["latestConfigurations": value.providerConfigurations.map { configuration in
                var json: [String: Any] = ["provider": configuration.provider.rawValue]
                if configuration.provider == .ethereum {
                    json["results"] = configuration.address.map { [$0] } ?? []
                    json["chainId"] = configuration.chainId
                } else { json["publicKey"] = configuration.address }
                return json
            }]
        }
        let admitted = try await store.enqueue(rawObject: [
            "id": request.id, "name": request.name, "provider": request.provider.rawValue,
            "body": body, "host": request.host, "configurationKey": request.configurationKey,
            "enqueueAttempt": request.enqueueAttempt, "workflowVersion": ExtensionBridge.workflowVersion,
        ], profileIdentifier: template.handle.profileIdentifier,
           approvedAccount: request.authorizedAccount)
        if let receipt = template.nativeDeliveryReceipt {
            await store.setNativeDeliveryReceipt(receipt, handle: admitted.handle)
        }
        if template.phase == .approving { try await store.holdForeignClaim(handle: admitted.handle) }
        return try await store.snapshot(handle: admitted.handle)
    }

    private func popupController(store: ApprovalStoreTestFixture) -> PopupRequestSessions {
        return PopupRequestSessions(
            store: store,
            walletEnvironment: popupWalletEnvironment(),
            loadsTransactionContext: false,
            approvalNetworkResolver: popupApprovalNetwork,
            executionEnvironment: .init(
                requestProcessor: CompactPopupProcessor()
            )
        )
    }

    private func retryApproval(
        controller: PopupRequestSessions,
        snapshot: ExtensionBridge.Snapshot
    ) async throws -> WireProtocol.JSONObject {
        try await controller.dispatchPreparedJSON(request: try popupCommand(
            subject: "retryApproval", id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        ), profileIdentifier: snapshot.handle.profileIdentifier)
    }

    private func materializeToken(
        controller: PopupRequestSessions,
        snapshot: ExtensionBridge.Snapshot
    ) async throws -> String {
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )
        let state = try await controller.dispatchPreparedJSON(
            request: request,
            profileIdentifier: snapshot.handle.profileIdentifier
        )
        return try XCTUnwrap((state["review"] as? [String: Any])?["reviewToken"] as? String)
    }

    private func waitForEvent(
        _ event: String,
        store: ApprovalStoreTestFixture
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.events().contains(event) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw PopupRequestSessionsTestError.timedOut
    }

    private func waitForCondition(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw PopupRequestSessionsTestError.timedOut
    }
}

@MainActor
private final class CompactPopupProcessor: DappRequestProcessing {
    private let handler: ((SafariRequest) -> UnboundDappRequestPreparation)?
    private let walletIndependent: Bool
    private let execution: (SafariRequest, DappApprovalValidator.Approval, (any WalletSigning)?, ExtensionBridge.ApprovedExecutionPermit) async -> ApprovedExecutionResult
    private let processor = DappRequestProcessor(ethereumNetworkResolver: popupApprovalNetwork)

    convenience init(
        walletIndependent: Bool = false,
        handler: @escaping (SafariRequest) -> UnboundDappRequestPreparation
    ) {
        self.init(
            walletIndependent: walletIndependent,
            execute: { _, _, _, permit in approvedFailureForTesting(.userRejected, permit: permit) },
            handler: handler
        )
    }

    init(
        walletIndependent: Bool = false,
        execute: @escaping (SafariRequest, DappApprovalValidator.Approval, (any WalletSigning)?, ExtensionBridge.ApprovedExecutionPermit) async -> ApprovedExecutionResult = { _, _, _, permit in
            approvedFailureForTesting(.userRejected, permit: permit)
        },
        handler: ((SafariRequest) -> UnboundDappRequestPreparation)? = nil
    ) {
        self.walletIndependent = walletIndependent
        self.handler = handler
        self.execution = execute
    }

    func prepare(_ binding: ExtensionBridge.RequestBinding, catalog: WalletReviewCatalog) -> DappRequestPreparation {
        guard let handler else { return processor.prepare(binding, catalog: catalog) }
        return preparation(handler(binding.request), binding: binding)
    }

    func prepareWithoutWallets(_ binding: ExtensionBridge.RequestBinding) -> DappRequestPreparation? {
        guard let handler else { return processor.prepareWithoutWallets(binding) }
        return walletIndependent ? preparation(handler(binding.request), binding: binding) : nil
    }

    private func preparation(_ unbound: UnboundDappRequestPreparation, binding: ExtensionBridge.RequestBinding) -> DappRequestPreparation {
        switch unbound {
        case .immediate(let resolution): return .immediate(resolution)
        case .approval(let action): return preparationForTesting(binding: binding, action: action)
        case .unavailable: return .unavailable
        }
    }

    func execute(permit: ExtensionBridge.ApprovedExecutionPermit, signer: (any WalletSigning)?) async -> ApprovedExecutionResult {
        guard permit.consumeExecution() else { return .rollback }
        return await execution(permit.request, permit.approval, signer, permit)
    }
}

@MainActor
private final class PreparationRecordingDappRequestProcessor: DappRequestProcessing {
    private let processor = DappRequestProcessor(ethereumNetworkResolver: popupApprovalNetwork)
    private(set) var preparations = 0

    func prepare(_ binding: ExtensionBridge.RequestBinding, catalog: WalletReviewCatalog) -> DappRequestPreparation {
        preparations += 1
        return processor.prepare(binding, catalog: catalog)
    }

    func prepareWithoutWallets(_ binding: ExtensionBridge.RequestBinding) -> DappRequestPreparation? {
        processor.prepareWithoutWallets(binding)
    }

    func execute(permit: ExtensionBridge.ApprovedExecutionPermit, signer: (any WalletSigning)?) async -> ApprovedExecutionResult {
        await processor.execute(permit: permit, signer: signer)
    }
}

@MainActor
private final class CompactPopupAccessProcessor: DappRequestProcessing {
    private let handler: (SafariRequest, WalletReviewCatalog) -> UnboundDappRequestPreparation
    private let execution: (SafariRequest, DappApprovalValidator.Approval, (any WalletSigning)?, ExtensionBridge.ApprovedExecutionPermit) async -> ApprovedExecutionResult

    init(
        execute: @escaping (SafariRequest, DappApprovalValidator.Approval, (any WalletSigning)?, ExtensionBridge.ApprovedExecutionPermit) async -> ApprovedExecutionResult = { _, _, _, permit in
            approvedFailureForTesting(.userRejected, permit: permit)
        },
        handler: @escaping (SafariRequest, WalletReviewCatalog) -> UnboundDappRequestPreparation
    ) {
        self.handler = handler
        self.execution = execute
    }

    func prepare(_ binding: ExtensionBridge.RequestBinding, catalog: WalletReviewCatalog) -> DappRequestPreparation {
        switch handler(binding.request, catalog) {
        case .immediate(let resolution): return .immediate(resolution)
        case .approval(let action):
            return preparationForTesting(binding: binding, action: action, accounts: catalog.orderedAccounts)
        case .unavailable: return .unavailable
        }
    }

    func prepareWithoutWallets(_ binding: ExtensionBridge.RequestBinding) -> DappRequestPreparation? {
        nil
    }

    func execute(permit: ExtensionBridge.ApprovedExecutionPermit, signer: (any WalletSigning)?) async -> ApprovedExecutionResult {
        guard permit.consumeExecution() else { return .rollback }
        return await execution(permit.request, permit.approval, signer, permit)
    }
}

private final class PopupRecordingWalletSigningAccess: OwnedWalletSigningAccess {
    private struct State {
        var recordedOperations = [ApprovedWalletSigningOperation]()
        var invalidations = 0
    }
    private let state = Mutex(State())

    var operations: [ApprovedWalletSigningOperation] {
        state.withLock { $0.recordedOperations }
    }

    var invalidationCount: Int {
        state.withLock { $0.invalidations }
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        state.withLock { $0.recordedOperations.append(operation) }
        return walletSigningResultForTesting(operation)
    }

    func invalidate() {
        state.withLock { $0.invalidations += 1 }
    }
}

@MainActor
private final class PopupBroadcastSender: ApprovedBroadcastSending {
    private let ethereum: (String, ResolvedEthereumNetwork) async -> Result<String, EthereumSendFailure>

    init(
        ethereum: @escaping (String, ResolvedEthereumNetwork) async -> Result<String, EthereumSendFailure> = { _, _ in
            .failure(.rpc(.serverError(4001, Strings.canceled, dataJSON: nil)))
        }
    ) {
        self.ethereum = ethereum
    }

    func sendEthereum(signedTransaction: String, network: ResolvedEthereumNetwork) async -> Result<String, EthereumSendFailure> {
        await ethereum(signedTransaction, network)
    }

    func sendSolana(
        signedTransaction: String, cluster: Solana.Cluster, options: Solana.PreparedSendOptions
    ) async -> Result<String, Solana.SendTransactionError> {
        XCTFail("Expected an Ethereum broadcast")
        return .failure(.notSubmitted)
    }
}

@MainActor
private func popupPreparedBroadcast(
    permit: ExtensionBridge.ApprovedExecutionPermit,
    signer: (any WalletSigning)?
) async -> ApprovedExecutionResult {
    guard let signer,
          case .success(.broadcast(let signed)) = await signer.sign(),
          signed.executionID == permit.executionID else {
        if !Task.isCancelled { XCTFail("Expected a live approved transaction broadcast") }
        return .rollback
    }
    return .broadcast(PreparedBroadcast(signed: signed))
}

private extension WalletReviewCatalog {
    init(accounts: [SpecificWalletAccount], identity: WalletCatalogIdentity? = nil) {
        self.init(
            identity: identity ?? WalletCatalogIdentity(
                generation: UUID(),
                catalogData: Data("catalog".utf8)
            ),
            orderedAccounts: accounts
        )
    }

    init(account: WalletAccount) {
        self.init(accounts: [SpecificWalletAccount(walletId: "wallet", account: account)])
    }
}

private func popupExecutedTransaction(approval: DappApprovalValidator.Approval) -> Transaction? {
    guard case .signing(_, .ethereumTransaction(let transaction, _)) = approval.kind else { return nil }
    return transaction
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

private final class CompactExecutionClock: Sendable {
    private let value: Mutex<Date>

    init(_ value: Date) { self.value = Mutex(value) }

    var now: Date {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

private final class CompactExecutionLeaseState: Sendable {
    private struct State {
        var held: Bool
        var heldAtDurableCommit = false
        var releasedBeforeBroadcast = false
    }
    private let state: Mutex<State>

    init(held: Bool = true) { state = Mutex(State(held: held)) }
    func acquire() { state.withLock { $0.held = true } }
    var wasHeldAtDurableCommit: Bool { state.withLock { $0.heldAtDurableCommit } }
    var wasReleasedBeforeBroadcast: Bool { state.withLock { $0.releasedBeforeBroadcast } }
    var isReleased: Bool { state.withLock { !$0.held } }
    func observeDurableCommit() { state.withLock { $0.heldAtDurableCommit = $0.heldAtDurableCommit || $0.held } }
    func observeBroadcast() { state.withLock { $0.releasedBeforeBroadcast = !$0.held } }
    func release() { state.withLock { $0.held = false } }
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

private func popupTestAccountDescriptor() -> WalletAccountDescriptor {
    WalletAccountDescriptor(walletID: "wallet", account: popupTestAccount())
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
        from: popupTestAccount().address,
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

private func popupPreparedTransaction(_ transaction: Transaction) -> Transaction {
    var prepared = transaction
    prepared.nonce = prepared.nonce ?? "0x0"
    prepared.gas = prepared.gas ?? "0x5208"
    if prepared.preparedFee == nil {
        let requestedFee = prepared.feeIntent.preparedFee
        let fee = requestedFee ?? .legacy(gasPrice: 10)
        prepared.replacePreparedFee(
            fee, provenance: .init(source: requestedFee == nil ? .automatic : .dapp, for: fee)
        )
    }
    return prepared
}

private func popupTransactionAction() -> DappRequestAction {
    .approveTransaction(.init(
        transaction: popupReadyTransaction(),
        resolvedNetwork: .init(network: popupTransactionNetwork(), source: .custom),
        walletId: "wallet", account: popupTestAccount()
    ))
}

private func popupTransactionDecision() throws -> DappApprovalDecision.TransactionExecution {
    try XCTUnwrap(DappApprovalDecision.TransactionExecution(
        popupReadyTransaction(),
        reviewedNetwork: .init(network: popupTransactionNetwork(), source: .custom),
        approvedAccount: popupTestAccountDescriptor()
    ))
}

private func popupTransactionHashForTesting() throws -> String {
    let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
    let signed = try Ethereum.signedTransaction(
        transaction: popupReadyTransaction(), privateKey: key, network: popupTransactionNetwork()
    ).get()
    return try XCTUnwrap(Ethereum.transactionHash(signedTransaction: signed))
}

@MainActor
private func popupImmediateTransactionOperations() -> TransactionApprovalOperations {
    TransactionApprovalOperations(
        prepare: { transaction, _, _ in
            let source = PopupPreparationSource()
            let prepared = popupPreparedTransaction(transaction)
            source.update(prepared)
            source.resolve(.success(prepared))
            return source.stream
        },
        preflight: { transaction, _ in
            let source = PopupPreflightSource()
            source.resolve(.safe(transaction, popupTransactionEstimate()))
            return try await source.value(cancellation: nil)
        }
    )
}

private func popupSolanaTestAccount() -> WalletAccount {
    WalletAccount(
        address: "11111111111111111111111111111111",
        coin: .solana,
        derivation: .solanaSolana,
        derivationPath: "m/44'/501'/0'/0'",
        publicKey: "",
        extendedPublicKey: ""
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

private func popupApprovalNetwork(chainID: Int) -> ApprovalNetworkResolution {
    popupSigningNetwork(chainID: chainID).map(ApprovalNetworkResolution.resolved) ?? .missing
}

private func popupSigningNetwork(chainID: Int) -> ResolvedEthereumNetwork? {
    let network = popupTransactionNetwork()
    guard chainID == network.chainId else { return nil }
    return ResolvedEthereumNetwork(network: network, source: .custom)
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
        "configurationKey": "https://wallet.example",
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
        state: .queued(request: request, approval: .unowned),
        nativeDeliveryNonce: .init(value: UUID()),
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
    profileIdentifier: UUID? = nil,
    createdAt: Date = Date(),
    provider: InpageProvider = .unknown,
    method: String? = nil,
    revisions: ExtensionBridge.ProviderRevisions = popupRevisions(),
    phase: ExtensionBridge.Phase = .queued,
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
                "chainId": "0xa",
                "object": [
                    "to": "0x0000000000000000000000000000000000000002",
                    "nonce": "0x0", "gas": "0x5208", "value": "0x0", "data": "0x", "gasPrice": "0xa",
                ],
            ]
        } else if name == "addEthereumChain" {
            let network = popupTestNetwork()
            body = [
                "address": popupTestAccount().address, "chainId": "0x1",
                "object": try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(network)) as? [String: Any]),
            ]
        } else if name == "signPersonalMessage" {
            body = [
                "address": popupTestAccount().address, "chainId": "0x1",
                "object": ["data": WalletCrypto.hexString(data: Data("reviewed".utf8))],
            ]
        } else {
            body = ["address": popupTestAccount().address]
        }
    case .solana:
        name = method ?? "connect"
        let publicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: popupSolanaTestAccount().address))
        let wireMessage = WalletCrypto.base58Encode(data: SolanaMessageFixture.wireMessage(
            accountKeys: [publicKey], bodyAfterBlockhash: Data.encodeLength(0)
        ))
        let parameters: [String: Any]
        switch name {
        case "signMessage":
            parameters = ["message": WalletCrypto.hexString(data: Data("reviewed".utf8)), "messageEncoding": "hex"]
        case "signAllTransactions":
            parameters = ["messages": [wireMessage]]
        case "signTransaction", "signAndSendTransaction":
            parameters = ["message": wireMessage]
        default:
            parameters = [:]
        }
        body = [
            "publicKey": popupSolanaTestAccount().address,
            "object": ["params": parameters],
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
        "configurationKey": "https://wallet.example",
        "enqueueAttempt": String(format: "%032x", id),
        "admissionDeadline": popupRequestAdmissionDeadline,
        "workflowVersion": ExtensionBridge.workflowVersion,
        "body": body,
    ])
    var request = try XCTUnwrap(SafariRequest(data: data))
    if provider == .ethereum, name != "requestAccounts" { request.authorizedAccount = popupTestAccountDescriptor() }
    if provider == .solana, name != "connect" {
        request.authorizedAccount = WalletAccountDescriptor(walletID: "wallet", account: popupSolanaTestAccount())
    }
    let handle = ExtensionBridge.Handle(
        id: id,
        token: .init(value: UUID()),
        profileIdentifier: profileIdentifier
    )
    let nonce = nativeDeliveryReceipt?.nativeDeliveryNonce ?? ExtensionBridge.NativeDeliveryNonce(value: UUID())
    let state: ExtensionBridge.Snapshot.State
    switch phase {
    case .queued:
        state = .queued(request: request, approval:
            nativeDeliveryReceipt.map { .delivered($0) } ?? .unowned)
    case .approving:
        state = .approving(request: request, nativeApproval: nil)
    case .responded:
        state = .responded
    }
    return ExtensionBridge.Snapshot(
        handle: handle,
        state: state,
        nativeDeliveryNonce: nonce,
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
        workflowVersion: ExtensionBridge.workflowVersion,
        launchedAt: launchDate
    )
}
#endif

private func popupCommand(
    subject: String,
    id: Int,
    requestToken: String? = nil,
    reviewToken: String? = nil,
    payload: [String: Any]? = nil
) throws -> InternalSafariRequest {
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

@MainActor
private func popupWalletEnvironment(
    reviewCatalog: (@MainActor @Sendable () -> WalletReviewCatalog?)? = nil,
    unlockWallets: @escaping @MainActor @Sendable (String, WalletSigningAuthorization) async -> WalletUnlockResult = { _, _ in .canceled }
) -> PopupWalletEnvironment {
    let catalog = WalletReviewCatalog(account: popupTestAccount())
    return PopupWalletEnvironment(
        reviewCatalog: reviewCatalog ?? { catalog },
        unlockWallets: unlockWallets
    )
}

@MainActor
private extension PopupRequestSessions {
    func dispatchPreparedJSON(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async throws -> WireProtocol.JSONObject {
        var state = await dispatchJSON(request: request, profileIdentifier: profileIdentifier)
        let status = state["status"]
        let deadline = ContinuousClock.now + .seconds(2)
        while let review = state["review"] as? [String: Any],
              review["kind"] as? String == "sendTransaction",
              review["canBackOffRefresh"] as? Bool == false {
            guard ContinuousClock.now < deadline else { throw PopupRequestSessionsTestError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
            state = await dispatchJSON(
                request: try popupCommand(subject: "getApprovalState", id: request.id, requestToken: request.requestToken),
                profileIdentifier: profileIdentifier
            )
        }
        var json = state.json
        json["status"] = status
        return try XCTUnwrap(WireProtocol.JSONObject(json))
    }

    func dispatchJSON(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> WireProtocol.JSONObject {
        let json = popupResponseJSON(await dispatch(request: request, profileIdentifier: profileIdentifier))
        if case .popup(.getPendingRequests) = request.command { return WireProtocol.JSONObject(json)! }
        XCTAssertEqual(Set(json.keys), ["status", "approval"])
        let status = json["status"] as? String
        XCTAssertTrue(["ok", "ignored", "unavailable"].contains(status ?? ""))
        if var approval = json["approval"] as? [String: Any] {
            XCTAssertEqual(approval["id"] as? Int, request.id)
            approval["status"] = status
            return WireProtocol.JSONObject(approval)!
        }
        XCTAssertNotEqual(status, "ok")
        XCTAssertTrue(json["approval"] is NSNull)
        return WireProtocol.JSONObject(json)!
    }
}

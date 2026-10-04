// ∅ 2026 lil org

import XCTest
import Synchronization
@testable import Big_Wallet

@MainActor
final class TransactionApprovalCoordinatorTests: XCTestCase {

    func testPreparationStateRequiresCurrentTerminalSuccess() async {
        let firstTransactionID = UUID()
        let secondTransactionID = UUID()
        var state = TransactionPreparationState()

        let firstAttempt = state.beginPreparation(
            for: firstTransactionID
        )
        state.beginEditing(secondTransactionID)
        XCTAssertFalse(
            state.markReady(
                attemptID: firstAttempt,
                transactionID: firstTransactionID
            )
        )

        let secondAttempt = state.beginPreparation(
            for: secondTransactionID
        )
        XCTAssertTrue(
            state.markReady(
                attemptID: secondAttempt,
                transactionID: secondTransactionID
            )
        )
        XCTAssertTrue(
            state.canApprove(
                transactionID: secondTransactionID,
                transactionIsReady: true
            )
        )

        state.finish()
        XCTAssertEqual(state.phase, .finished)
        XCTAssertFalse(state.allowsMutation)
    }

    func testPreparationStateSerializesAuthenticationAndPreflight() async {
        let transactionID = UUID()
        var state = TransactionPreparationState()
        let attemptID = state.beginPreparation(for: transactionID)

        XCTAssertTrue(
            state.markReady(
                attemptID: attemptID,
                transactionID: transactionID
            )
        )
        let authenticationAttempt = state.beginAuthentication(
            for: transactionID
        )
        XCTAssertEqual(authenticationAttempt, attemptID + 1)
        XCTAssertFalse(state.allowsMutation)
        XCTAssertTrue(
            state.restoreReady(
                attemptID: authenticationAttempt!,
                transactionID: transactionID
            )
        )
        XCTAssertEqual(
            state.beginPreflight(for: transactionID),
            authenticationAttempt
        )
        XCTAssertTrue(
            state.beginUnsafeFeeEditing(
                attemptID: authenticationAttempt!,
                transactionID: transactionID
            )
        )
        XCTAssertEqual(state.phase, .editing)
        XCTAssertEqual(state.attemptID, authenticationAttempt! + 1)
    }

    func testPreparationRestartGateCoalescesMutations() async {
        var gate = TransactionPreparationRestartGate()

        XCTAssertTrue(gate.recordMutation())
        for _ in 0..<20 {
            XCTAssertFalse(gate.recordMutation())
        }
        XCTAssertTrue(gate.consume())
        XCTAssertFalse(gate.consume())
    }

    func testApproveReturnsWhetherApprovalFlowStarted() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)

        XCTAssertFalse(coordinator.approve())
        await prepareToReady(coordinator, stub: stub)
        XCTAssertTrue(coordinator.approve())
        XCTAssertFalse(coordinator.approve())
    }

    func testPreparationTokenIncludesAttemptTransactionAndKind() async {
        let transaction = Self.makeReadyTransaction()
        var reducer = TransactionApprovalReducer(
            transaction: transaction,
            network: Self.makeNetwork(),
            authenticationPolicy: .skipped
        )

        let effects = reducer.reduce(
            .startPreparation(forceGasCheck: true)
        )
        guard case .runPreparation(
            let token,
            let effectTransaction,
            let forceGasCheck
        ) = effects.last else {
            return XCTFail("Expected a preparation effect")
        }

        XCTAssertEqual(token.attemptID, 1)
        XCTAssertEqual(token.transactionID, transaction.id)
        XCTAssertEqual(token.kind, .preparation)
        XCTAssertEqual(effectTransaction.id, transaction.id)
        XCTAssertTrue(forceGasCheck)
    }

    func testNewAttemptCancelsPriorBeforeStartingAndStaleResultCannotClearNewerHandle() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)

        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 0 }
        let first = stub.preparationCalls[0]
        coordinator.startPreparation(forceGasCheck: true)
        await waitFor { stub.preparationCalls.count > 1 }
        let second = stub.preparationCalls[1]

        await waitFor { first.cancellation.isCancelled }
        XCTAssertTrue(first.cancellation.isCancelled)

        var staleUpdate = first.transaction
        staleUpdate.interpretation = "stale"
        first.onUpdate(staleUpdate)
        first.onFeeEstimate(Self.makeEstimate())
        first.completion(.failure(.gasEstimationFailed))
        await waitFor { (coordinator.snapshot.phase) == (.preparing) }
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
        XCTAssertNil(coordinator.snapshot.transaction.interpretation)
        await waitFor { !(coordinator.snapshot.hasVerifiedFeeEstimate) }
        XCTAssertFalse(coordinator.snapshot.hasVerifiedFeeEstimate)
        await waitFor { !(second.cancellation.isCancelled) }
        XCTAssertFalse(second.cancellation.isCancelled)

        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { second.cancellation.isCancelled }
        XCTAssertTrue(second.cancellation.isCancelled)
        await waitFor { stub.preparationCalls.count > 2 && (!(stub.preparationCalls[2].cancellation.isCancelled)) }
        XCTAssertFalse(
            stub.preparationCalls[2].cancellation.isCancelled
        )
    }

    func testPreparationUpdateWinsOverTerminalSnapshot() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 0 }
        let call = stub.preparationCalls[0]

        var updated = call.transaction
        updated.interpretation = "Latest accepted update"
        call.onUpdate(updated)

        var terminal = call.transaction
        terminal.interpretation = "Older terminal snapshot"
        call.completion(.success(terminal))

        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        await waitFor { (coordinator.snapshot.transaction.interpretation) == ("Latest accepted update") }
        XCTAssertEqual(
            coordinator.snapshot.transaction.interpretation,
            "Latest accepted update"
        )
    }

    func testLatePreparationUpdateAfterCompletionUpdatesReadySnapshot() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 0 }
        let call = stub.preparationCalls[0]

        call.completion(.success(call.transaction))
        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        await waitFor { coordinator.snapshot.canApprove }
        XCTAssertTrue(coordinator.snapshot.canApprove)
        await waitFor { !(call.cancellation.isCancelled) }
        XCTAssertFalse(call.cancellation.isCancelled)

        var lateUpdate = call.transaction
        lateUpdate.interpretation = "Late interpretation"
        call.onUpdate(lateUpdate)

        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        await waitFor { (coordinator.snapshot.transaction.interpretation) == ("Late interpretation") }
        XCTAssertEqual(
            coordinator.snapshot.transaction.interpretation,
            "Late interpretation"
        )
        await waitFor { coordinator.snapshot.canApprove }
        XCTAssertTrue(coordinator.snapshot.canApprove)
    }

    func testLatePreparationUpdateIsIgnoredAfterReadyAdvancesToPreflight() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 0 }
        let preparation = stub.preparationCalls[0]
        preparation.completion(.success(preparation.transaction))
        await waitFor { coordinator.snapshot.phase == .ready }

        coordinator.approve()
        await waitFor { (coordinator.snapshot.phase) == (.preflighting) }
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
        await waitFor { (stub.preflightCalls.count) == (1) }
        XCTAssertEqual(stub.preflightCalls.count, 1)

        var lateUpdate = preparation.transaction
        lateUpdate.interpretation = "Too late"
        preparation.onUpdate(lateUpdate)

        await waitFor { (coordinator.snapshot.phase) == (.preflighting) }
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
        XCTAssertNil(coordinator.snapshot.transaction.interpretation)
    }

    func testSynchronousCompletionCannotRetainOldHandleOrOverwriteReentrantRequest() async {
        let stub = ApprovalOperationsStub()
        var coordinator: TransactionApprovalCoordinator!
        var didRestart = false
        stub.synchronousPreparation = { call in
            guard stub.preparationCalls.count == 1 else { return }
            call.completion(.success(call.transaction))
        }
        coordinator = TransactionApprovalCoordinator(
            transaction: Self.makeReadyTransaction(),
            network: Self.makeNetwork(),
            authenticationPolicy: .skipped,
            operations: stub.operations
        ) { output in
            guard case .snapshot(let snapshot) = output,
                  snapshot.phase == .ready,
                  !didRestart else {
                return
            }
            didRestart = true
            coordinator.startPreparation(forceGasCheck: false)
        }

        coordinator.startPreparation(forceGasCheck: false)

        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        await waitFor { stub.preparationCalls.count > 0 && (stub.preparationCalls[0].cancellation.isCancelled) }
        XCTAssertTrue(stub.preparationCalls[0].cancellation.isCancelled)
        await waitFor { stub.preparationCalls.count > 1 && (!(stub.preparationCalls[1].cancellation.isCancelled)) }
        XCTAssertFalse(stub.preparationCalls[1].cancellation.isCancelled)
        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 1 && (stub.preparationCalls[1].cancellation.isCancelled) }
        XCTAssertTrue(stub.preparationCalls[1].cancellation.isCancelled)
    }

    func testFailureRetryPreservesForcePolicyAndClearsUnverifiedBaseFees() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        var transaction = Self.makeReadyTransaction()
        transaction.currentBaseFeePerGas = 11
        transaction.nextBaseFeePerGas = 12
        let coordinator = makeCoordinator(
            transaction: transaction,
            stub: stub,
            recorder: recorder
        )

        coordinator.startPreparation(forceGasCheck: true)
        stub.preparationCalls[0].completion(
            .failure(.gasEstimationFailed)
        )

        await waitFor { (coordinator.snapshot.phase) == (.failed) }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        XCTAssertNil(
            coordinator.snapshot.transaction.currentBaseFeePerGas
        )
        XCTAssertNil(coordinator.snapshot.transaction.nextBaseFeePerGas)
        await waitFor { recorder.alerts.last != nil }
        let alert = try! XCTUnwrap(recorder.alerts.last)
        guard case .preparationFailure(
            .gasEstimationFailed,
            let forceGasCheck
        ) = alert.kind else {
            return XCTFail("Unexpected alert")
        }
        XCTAssertTrue(forceGasCheck)

        coordinator.handleAlert(token: alert.token, action: .retry)
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        await waitFor { stub.preparationCalls.count > 1 && (stub.preparationCalls[1].forceGasCheck) }
        XCTAssertTrue(stub.preparationCalls[1].forceGasCheck)
    }

    func testEstimateBeforeFailurePreservesVerifiedBaseFees() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 0 }
        let call = stub.preparationCalls[0]

        call.onFeeEstimate(Self.makeEstimate())
        call.completion(.failure(.gasEstimationFailed))

        await waitFor { coordinator.snapshot.hasVerifiedFeeEstimate }
        XCTAssertTrue(coordinator.snapshot.hasVerifiedFeeEstimate)
        await waitFor { (coordinator.snapshot.transaction.currentBaseFeePerGas) == (90) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.currentBaseFeePerGas,
            90
        )
        await waitFor { (coordinator.snapshot.transaction.nextBaseFeePerGas) == (100) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.nextBaseFeePerGas,
            100
        )
    }

    func testEditsInvalidateTransactionAttemptAndDeferredAlert() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        coordinator.startPreparation(forceGasCheck: false)
        stub.preparationCalls[0].completion(
            .failure(.gasEstimationFailed)
        )
        await waitFor { recorder.alerts.last != nil }
        let alert = try! XCTUnwrap(recorder.alerts.last)
        let oldTransactionID = coordinator.snapshot.transaction.id
        let oldAttemptID = coordinator.snapshot.attemptID
        XCTAssertTrue(coordinator.isCurrentAlert(alert.token))

        XCTAssertTrue(
            coordinator.apply(edits: Transaction.Edits(nonce: 1))
        )

        XCTAssertNotEqual(
            coordinator.snapshot.transaction.id,
            oldTransactionID
        )
        XCTAssertGreaterThan(coordinator.snapshot.attemptID, oldAttemptID)
        XCTAssertFalse(coordinator.isCurrentAlert(alert.token))
        coordinator.handleAlert(token: alert.token, action: .retry)
        await waitFor { (stub.preparationCalls.count) == (1) }
        XCTAssertEqual(stub.preparationCalls.count, 1)
    }

    func testRequiredAuthenticationFailureRestoresReady() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)

        coordinator.approve()

        await waitFor { stub.preparationCalls.count > 0 && (stub.preparationCalls[0].cancellation.isCancelled) }
        XCTAssertTrue(stub.preparationCalls[0].cancellation.isCancelled)
        let token = try! XCTUnwrap(recorder.authenticationTokens.last)
        XCTAssertEqual(token.kind, .authentication)
        XCTAssertEqual(token.attemptID, coordinator.snapshot.attemptID)
        XCTAssertEqual(
            token.transactionID,
            coordinator.snapshot.transaction.id
        )
        await waitFor { (coordinator.snapshot.phase) == (.authenticating) }
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)
        await waitFor { !(coordinator.snapshot.allowsMutation) }
        XCTAssertFalse(coordinator.snapshot.allowsMutation)

        coordinator.authenticationCompleted(
            token: token,
            succeeded: false
        )
        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        await waitFor { coordinator.snapshot.canApprove }
        XCTAssertTrue(coordinator.snapshot.canApprove)
    }

    func testRequiredAuthenticationSuccessStartsOnePreflightAndRejectsRepeatedResult() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let token = recorder.authenticationTokens.last!
        await waitFor { stub.preflightCalls.isEmpty }
        XCTAssertTrue(stub.preflightCalls.isEmpty)

        coordinator.authenticationCompleted(
            token: token,
            succeeded: true
        )
        coordinator.authenticationCompleted(
            token: token,
            succeeded: true
        )
        coordinator.authenticationCompleted(
            token: token,
            succeeded: false
        )

        await waitFor { (stub.preflightCalls.count) == (1) }
        XCTAssertEqual(stub.preflightCalls.count, 1)
        await waitFor { (coordinator.snapshot.phase) == (.preflighting) }
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
    }

    func testCancelWhileAuthenticatingRejectsLateAuthentication() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let token = recorder.authenticationTokens.last!
        await waitFor { (coordinator.snapshot.phase) == (.authenticating) }
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)

        coordinator.cancel()
        coordinator.authenticationCompleted(
            token: token,
            succeeded: true
        )

        await waitFor { stub.preflightCalls.isEmpty }
        XCTAssertTrue(stub.preflightCalls.isEmpty)
        await waitFor { (recorder.completions.count) == (1) }
        XCTAssertEqual(recorder.completions.count, 1)
        XCTAssertNil(recorder.completions[0])
        await waitFor { (coordinator.snapshot.phase) == (.finished) }
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
    }

    func testFailedAuthenticationTokenCannotAuthorizeRetry() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)

        coordinator.approve()
        let firstToken = recorder.authenticationTokens.last!
        coordinator.authenticationCompleted(
            token: firstToken,
            succeeded: false
        )

        coordinator.approve()
        let secondToken = recorder.authenticationTokens.last!
        XCTAssertNotEqual(firstToken, secondToken)
        await waitFor { (coordinator.snapshot.phase) == (.authenticating) }
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)

        coordinator.authenticationCompleted(
            token: firstToken,
            succeeded: true
        )
        await waitFor { stub.preflightCalls.isEmpty }
        XCTAssertTrue(stub.preflightCalls.isEmpty)
        await waitFor { (coordinator.snapshot.phase) == (.authenticating) }
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)

        coordinator.authenticationCompleted(
            token: secondToken,
            succeeded: true
        )
        await waitFor { (stub.preflightCalls.count) == (1) }
        XCTAssertEqual(stub.preflightCalls.count, 1)
        await waitFor { (coordinator.snapshot.phase) == (.preflighting) }
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
    }

    func testSkippedAuthenticationStartsPreflightDirectly() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .skipped,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)

        coordinator.approve()

        await waitFor { recorder.authenticationTokens.isEmpty }
        XCTAssertTrue(recorder.authenticationTokens.isEmpty)
        await waitFor { (stub.preflightCalls.count) == (1) }
        XCTAssertEqual(stub.preflightCalls.count, 1)
        await waitFor { (coordinator.snapshot.phase) == (.preflighting) }
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
    }

    func testSafePreflightCompletesExactlyOnceAcrossReentrantAndStaleEvents() async {
        let stub = ApprovalOperationsStub()
        var completions = [Transaction?]()
        var coordinator: TransactionApprovalCoordinator!
        coordinator = TransactionApprovalCoordinator(
            transaction: Self.makeReadyTransaction(),
            network: Self.makeNetwork(),
            authenticationPolicy: .skipped,
            operations: stub.operations
        ) { output in
            guard case .completion(let transaction) = output else {
                return
            }
            completions.append(transaction)
            coordinator.cancel()
        }
        await prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = stub.preflightCalls[0]
        let result = TransactionFeePreflightResult.safe(
            preflight.transaction,
            Self.makeEstimate()
        )

        preflight.completion(result)
        preflight.completion(result)
        await waitFor { completions.count == 1 }
        coordinator.cancel()

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(
            (completions.first ?? nil)?.id,
            preflight.transaction.id
        )
        await waitFor { (coordinator.snapshot.phase) == (.finished) }
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
    }

    func testPreflightSafeWithUnknownNoDataEstimatePreservesBaseFeesForSend()
        async throws
    {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let network = Self.makeCatalogHintedNetwork()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 150),
            network: network,
            stub: stub,
            recorder: recorder
        )
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)
        call.onFeeEstimate(Self.makeEstimate())
        call.completion(.success(call.transaction))
        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        coordinator.approve()
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .safe(preflight.transaction, Self.makeUnknownEstimate())
        )

        await waitFor { (recorder.completions.count) == (1) }
        XCTAssertEqual(recorder.completions.count, 1)
        let completed = try XCTUnwrap(recorder.completions[0])
        XCTAssertEqual(completed.currentBaseFeePerGas, 90)
        XCTAssertEqual(completed.nextBaseFeePerGas, 100)
        XCTAssertTrue(completed.isReadyForApproval(on: network))
    }

    func testPreparationUnknownEstimateAfterEIP1559EstimateKeepsBaseFees() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let network = Self.makeCatalogHintedNetwork()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 150),
            network: network,
            stub: stub,
            recorder: recorder
        )
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)

        call.onFeeEstimate(Self.makeEstimate())
        call.onFeeEstimate(Self.makeUnknownEstimate())

        await waitFor { (recorder.estimates.count) == (2) }
        XCTAssertEqual(recorder.estimates.count, 2)
        await waitFor { (coordinator.snapshot.transaction.currentBaseFeePerGas) == (90) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.currentBaseFeePerGas,
            90
        )
        await waitFor { (coordinator.snapshot.transaction.nextBaseFeePerGas) == (100) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.nextBaseFeePerGas,
            100
        )
        call.completion(.success(call.transaction))
        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertTrue(
            coordinator.snapshot.transaction.isReadyForApproval(on: network)
        )
    }

    func testPreflightSafeWithUnknownDataEstimateAdoptsObservedBaseFee()
        async throws
    {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let network = Self.makeCatalogHintedNetwork()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 150),
            network: network,
            stub: stub,
            recorder: recorder
        )
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)
        call.onFeeEstimate(Self.makeEstimate())
        call.completion(.success(call.transaction))
        await waitFor { coordinator.snapshot.phase == .ready }
        coordinator.approve()
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = try XCTUnwrap(stub.preflightCalls.first)

        preflight.completion(
            .safe(
                preflight.transaction,
                Self.makeUnknownEstimate(currentBaseFee: 120)
            )
        )

        await waitFor { (recorder.completions.count) == (1) }
        XCTAssertEqual(recorder.completions.count, 1)
        let completed = try XCTUnwrap(recorder.completions[0])
        XCTAssertEqual(completed.currentBaseFeePerGas, 120)
        XCTAssertNil(completed.nextBaseFeePerGas)
        XCTAssertTrue(completed.isReadyForApproval(on: network))
    }

    func testPreparationLegacyEstimateClearsBaseFees() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 150),
            stub: stub
        )
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)

        call.onFeeEstimate(Self.makeEstimate())
        call.onFeeEstimate(Self.makeLegacyEstimate())

        XCTAssertNil(
            coordinator.snapshot.transaction.currentBaseFeePerGas
        )
        XCTAssertNil(coordinator.snapshot.transaction.nextBaseFeePerGas)
    }

    func testWalletManagedUpdateInstallsCanonicalStateAndAcknowledgmentRestarts() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = stub.preflightCalls[0]
        let updated = Self.makeReadyTransaction(
            id: preflight.transaction.id,
            gasPrice: 99,
            feeSource: .slider
        )

        preflight.completion(
            .walletManagedUpdated(updated, Self.makeEstimate())
        )

        await waitFor { (coordinator.snapshot.transaction.preparedFee) == (.legacy(gasPrice: 99)) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.preparedFee,
            .legacy(gasPrice: 99)
        )
        await waitFor { (coordinator.snapshot.transaction.nextBaseFeePerGas) == (100) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.nextBaseFeePerGas,
            100
        )
        await waitFor { recorder.alerts.last != nil }
        let alert = try! XCTUnwrap(recorder.alerts.last)
        XCTAssertEqual(alert.kind, .feesUpdated)
        XCTAssertTrue(coordinator.isCurrentAlert(alert.token))
        await waitFor { (coordinator.snapshot.phase) == (.reviewingFees) }
        XCTAssertEqual(coordinator.snapshot.phase, .reviewingFees)

        preflight.completion(.safe(updated, Self.makeEstimate()))
        await waitFor { recorder.completions.isEmpty }
        XCTAssertTrue(recorder.completions.isEmpty)
        await waitFor { (coordinator.snapshot.phase) == (.reviewingFees) }
        XCTAssertEqual(coordinator.snapshot.phase, .reviewingFees)

        coordinator.handleAlert(
            token: alert.token,
            action: .acknowledge
        )

        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        await waitFor { stub.preparationCalls.count > 1 && (!(stub.preparationCalls[1].forceGasCheck)) }
        XCTAssertFalse(stub.preparationCalls[1].forceGasCheck)
        await waitFor { (coordinator.snapshot.phase) == (.preparing) }
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
        XCTAssertFalse(coordinator.isCurrentAlert(alert.token))

        preflight.completion(
            .safe(preflight.transaction, Self.makeEstimate())
        )
        await waitFor { (coordinator.snapshot.phase) == (.preparing) }
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
        await waitFor { (coordinator.snapshot.transaction.preparedFee) == (.legacy(gasPrice: 99)) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.preparedFee,
            .legacy(gasPrice: 99)
        )
        await waitFor { recorder.completions.isEmpty }
        XCTAssertTrue(recorder.completions.isEmpty)
        await waitFor { stub.preparationCalls.count > 1 && (!(stub.preparationCalls[1].cancellation.isCancelled)) }
        XCTAssertFalse(stub.preparationCalls[1].cancellation.isCancelled)
    }

    func testUnsafePreflightAdvancesEditingAttemptBeforeAlert() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        let preflightAttempt = coordinator.snapshot.attemptID
        coordinator.approve()
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .userControlledUnsafe(
                preflight.transaction,
                Self.makeEstimate()
            )
        )

        await waitFor { recorder.alerts.last != nil }
        let alert = try! XCTUnwrap(recorder.alerts.last)
        await waitFor { (coordinator.snapshot.phase) == (.editing) }
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
        await waitFor { (coordinator.snapshot.attemptID) == (preflightAttempt + 1) }
        XCTAssertEqual(
            coordinator.snapshot.attemptID,
            preflightAttempt + 1
        )
        XCTAssertEqual(
            alert.token.attemptID,
            coordinator.snapshot.attemptID
        )
        XCTAssertEqual(alert.token.kind, .unsafeFees)

        coordinator.handleAlert(token: alert.token, action: .edit)
        await waitFor { (recorder.editorRequestCount) == (1) }
        XCTAssertEqual(recorder.editorRequestCount, 1)
    }

    func testUnavailablePreflightFailsAndEmitsRetryableAlert() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .unavailable(preflight.transaction, Self.makeEstimate())
        )

        await waitFor { (coordinator.snapshot.phase) == (.failed) }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        await waitFor { recorder.alerts.last != nil }
        let alert = try! XCTUnwrap(recorder.alerts.last)
        XCTAssertEqual(alert.kind, .unavailableFees)
        coordinator.handleAlert(token: alert.token, action: .retry)
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
    }

    func testSliderMutationsCoalesceAndNoninteractiveMutationRestarts() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub, estimate: Self.makeEstimate())
        let readyAttempt = coordinator.snapshot.attemptID

        coordinator.beginSliderInteraction()
        coordinator.beginSliderInteraction()
        XCTAssertTrue(
            coordinator.setFeeForSpeed(value: 100)
        )
        let editingAttempt = coordinator.snapshot.attemptID
        XCTAssertEqual(editingAttempt, readyAttempt + 1)
        XCTAssertTrue(
            coordinator.setFeeForSpeed(value: 50)
        )
        await waitFor { (coordinator.snapshot.attemptID) == (editingAttempt) }
        XCTAssertEqual(coordinator.snapshot.attemptID, editingAttempt)
        XCTAssertTrue(coordinator.endSliderInteraction())
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertFalse(coordinator.endSliderInteraction())

        stub.preparationCalls[1].completion(
            .success(stub.preparationCalls[1].transaction)
        )
        await waitFor { coordinator.snapshot.phase == .ready }
        XCTAssertTrue(
            coordinator.setFeeForSpeed(value: 0)
        )
        await waitFor { (stub.preparationCalls.count) == (3) }
        XCTAssertEqual(stub.preparationCalls.count, 3)
        await waitFor { (coordinator.snapshot.phase) == (.preparing) }
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
    }

    func testCancelledSliderEndConsumesPendingMutationWithoutRestart() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub, estimate: Self.makeEstimate())

        coordinator.beginSliderInteraction()
        XCTAssertTrue(
            coordinator.setFeeForSpeed(value: 100)
        )
        XCTAssertTrue(
            coordinator.endSliderInteraction(cancelled: true)
        )
        await waitFor { (stub.preparationCalls.count) == (1) }
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertFalse(coordinator.endSliderInteraction())
        await waitFor { (coordinator.snapshot.phase) == (.editing) }
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
    }

    func testSliderWithoutMovementAppliesPendingQuoteAndPublishesWithoutRestart() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(transaction: Self.makeReadyTransaction(gasPrice: 120), stub: stub)
        let firstQuote = expectation(description: "initial quote received")
        let secondQuote = expectation(description: "pending quote received")
        var quoteCount = 0
        coordinator.onOutput = { output in
            if case .verifiedFeeEstimate = output {
                quoteCount += 1
                (quoteCount == 1 ? firstQuote : secondQuote).fulfill()
            }
        }
        coordinator.startPreparation(forceGasCheck: false)
        let preparation = stub.preparationCalls[0]
        preparation.onFeeEstimate(Self.makeEstimate())
        await fulfillment(of: [firstQuote], timeout: 2)
        let transaction = coordinator.snapshot.transaction
        let initialPosition = coordinator.gasSliderPosition
        let newInfo = GasService.Info(recommendedPriorityFee: 100, highPriorityFee: 200)
        coordinator.beginSliderInteraction()
        preparation.onFeeEstimate(.init(info: newInfo, nextBaseFee: 100))
        await fulfillment(of: [secondQuote], timeout: 2)
        XCTAssertEqual(coordinator.gasSliderPosition, initialPosition)
        var publishedPositions = [Double]()
        coordinator.onOutput = { output in
            if case .snapshot = output { publishedPositions.append(coordinator.gasSliderPosition) }
        }
        XCTAssertFalse(coordinator.endSliderInteraction())
        XCTAssertEqual(publishedPositions, [transaction.currentFeeInRelationTo(info: newInfo)])
        XCTAssertEqual(coordinator.snapshot.transaction.id, transaction.id)
        XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, transaction.preparedFee)
        XCTAssertEqual(coordinator.snapshot.transaction.feeProvenance, transaction.feeProvenance)
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertFalse(coordinator.endSliderInteraction())
        XCTAssertEqual(publishedPositions.count, 1)
    }

    func testOneShotSpeedKeepsSelectedPositionThroughSynchronousPreparation() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 101),
            stub: stub
        )
        let initialInfo = GasService.Info(recommendedPriorityFee: 1, highPriorityFee: 2)
        await prepareToReady(
            coordinator,
            stub: stub,
            estimate: .init(info: initialInfo, nextBaseFee: 100)
        )
        let newInfo = GasService.Info(recommendedPriorityFee: 100, highPriorityFee: 200)
        stub.synchronousPreparation = { preparation in
            preparation.onUpdate(preparation.transaction)
            preparation.onFeeEstimate(.init(info: newInfo, nextBaseFee: 100))
            preparation.completion(.success(preparation.transaction))
        }
        var positionsDuringPreparation = [Double]()
        coordinator.onOutput = { output in
            if case .snapshot = output {
                positionsDuringPreparation.append(coordinator.gasSliderPosition)
            }
        }

        XCTAssertTrue(coordinator.setFeeForSpeed(value: 50))

        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertFalse(positionsDuringPreparation.isEmpty)
        XCTAssertTrue(positionsDuringPreparation.allSatisfy { $0 == 50 })
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        await waitFor { (coordinator.snapshot.transaction.preparedFee) == (.legacy(gasPrice: 101)) }
        XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, .legacy(gasPrice: 101))
        await waitFor { (coordinator.snapshot.transaction.feeProvenance.gasPrice) == (.slider) }
        XCTAssertEqual(coordinator.snapshot.transaction.feeProvenance.gasPrice, .slider)
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        coordinator.onOutput = { _ in }
        XCTAssertFalse(coordinator.endSliderInteraction())
        await waitFor {
            (coordinator.gasSliderPosition) == (coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo))
        }
        XCTAssertEqual(
            coordinator.gasSliderPosition,
            coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo)
        )
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 100))
        await waitFor { (coordinator.speedPriorityFeePerGas) == (100) }
        XCTAssertEqual(coordinator.speedPriorityFeePerGas, 100)
        coordinator.endSliderInteraction()
        await waitFor { (stub.preparationCalls.count) == (3) }
        XCTAssertEqual(stub.preparationCalls.count, 3)
    }

    func testDragReleaseAcceptsSynchronousQuoteBeforeTheNextGesture() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 120),
            stub: stub
        )
        await prepareToReady(coordinator, stub: stub, estimate: Self.makeEstimate())
        coordinator.beginSliderInteraction()
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 50))
        let selectedFee = coordinator.snapshot.transaction.preparedFee
        let newInfo = GasService.Info(recommendedPriorityFee: 100, highPriorityFee: 200)
        stub.synchronousPreparation = { preparation in
            preparation.onUpdate(preparation.transaction)
            preparation.onFeeEstimate(.init(info: newInfo, nextBaseFee: 100))
            preparation.completion(.success(preparation.transaction))
        }

        XCTAssertTrue(coordinator.endSliderInteraction())

        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        await waitFor { (coordinator.snapshot.transaction.preparedFee) == (selectedFee) }
        XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, selectedFee)
        await waitFor {
            (coordinator.gasSliderPosition) == (coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo))
        }
        XCTAssertEqual(
            coordinator.gasSliderPosition,
            coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo)
        )
        coordinator.beginSliderInteraction()
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 100))
        await waitFor { (coordinator.speedPriorityFeePerGas) == (100) }
        XCTAssertEqual(coordinator.speedPriorityFeePerGas, 100)
        XCTAssertTrue(coordinator.endSliderInteraction())
        await waitFor { (stub.preparationCalls.count) == (3) }
        XCTAssertEqual(stub.preparationCalls.count, 3)
    }

    func testManualEditsPublishUpdatedFallbackBeforeDeferredPreparation() async {
        let stub = ApprovalOperationsStub()
        var transaction = Self.makeReadyTransaction(gasPrice: 120)
        transaction.currentBaseFeePerGas = 100
        let coordinator = makeCoordinator(transaction: transaction, stub: stub)
        await prepareToReady(coordinator, stub: stub)
        var positions = [Double]()
        coordinator.onOutput = { output in
            if case .snapshot(let snapshot) = output {
                XCTAssertEqual(snapshot.transaction.preparedFee, .legacy(gasPrice: 140))
                XCTAssertEqual(coordinator.speedPriorityFeePerGas, 40)
                positions.append(coordinator.gasSliderPosition)
            }
        }

        XCTAssertTrue(coordinator.apply(edits: .init(gasPrice: 140)))

        XCTAssertEqual(positions, [GasSpeedConfiguration.recommendedSliderPosition])
        await waitFor { (coordinator.snapshot.phase) == (.editing) }
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
        await waitFor { (stub.preparationCalls.count) == (1) }
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertFalse(coordinator.apply(edits: .init()))
        XCTAssertEqual(positions.count, 1)
        await waitFor { (stub.preparationCalls.count) == (1) }
        XCTAssertEqual(stub.preparationCalls.count, 1)
        coordinator.onOutput = { _ in }
        coordinator.startPreparation(forceGasCheck: true)
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        await waitFor { stub.preparationCalls.count > 1 && (stub.preparationCalls[1].forceGasCheck) }
        XCTAssertTrue(stub.preparationCalls[1].forceGasCheck)
    }

    func testNonceOnlyEditsPreserveSelectedSliderPositionAndProvenance() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 101),
            stub: stub
        )
        let info = GasService.Info(recommendedPriorityFee: 1, highPriorityFee: 2)
        await prepareToReady(coordinator, stub: stub, estimate: .init(info: info, nextBaseFee: 100))
        coordinator.beginSliderInteraction()
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 50))
        coordinator.endSliderInteraction()
        await waitFor { stub.preparationCalls.count > 1 }
        let preparation = stub.preparationCalls[1]
        preparation.completion(.success(preparation.transaction))
        await waitFor { coordinator.snapshot.phase == .ready }
        let provenance = coordinator.snapshot.transaction.feeProvenance

        XCTAssertTrue(coordinator.apply(edits: .init(nonce: 1)))

        await waitFor { (coordinator.snapshot.transaction.decimalNonceString) == ("1") }
        XCTAssertEqual(coordinator.snapshot.transaction.decimalNonceString, "1")
        await waitFor { (coordinator.snapshot.transaction.feeProvenance) == (provenance) }
        XCTAssertEqual(coordinator.snapshot.transaction.feeProvenance, provenance)
        await waitFor { (coordinator.gasSliderPosition) == (50) }
        XCTAssertEqual(coordinator.gasSliderPosition, 50)
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
    }

    func testFailedAutomaticFeePreparationUnlocksManualFeeEditingAndRestart() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeAutomaticIntentTransaction(),
            stub: stub
        )
        coordinator.startPreparation(forceGasCheck: false)
        await waitFor { stub.preparationCalls.count > 0 }
        let first = stub.preparationCalls[0]

        first.completion(.failure(.gasPriceUnavailable))

        await waitFor { (coordinator.snapshot.phase) == (.failed) }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        await waitFor { coordinator.snapshot.canEdit }
        XCTAssertTrue(coordinator.snapshot.canEdit)
        await waitFor { !(coordinator.snapshot.canApprove) }
        XCTAssertFalse(coordinator.snapshot.canApprove)

        XCTAssertTrue(
            coordinator.apply(
                edits: Transaction.Edits(
                    preparedFee: .legacy(gasPrice: 123),
                    source: .manual,
                    replacementFeeProvenance:
                        TransactionFeeProvenance(gasPrice: .manual)
                )
            )
        )
        await waitFor { (coordinator.snapshot.phase) == (.editing) }
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
        await waitFor { !(first.cancellation.isCancelled) }
        XCTAssertFalse(first.cancellation.isCancelled)

        coordinator.startPreparation(forceGasCheck: true)
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        await waitFor { stub.preparationCalls.count > 1 }
        let second = stub.preparationCalls[1]
        XCTAssertTrue(second.forceGasCheck)
        XCTAssertEqual(
            second.transaction.preparedFee,
            .legacy(gasPrice: 123)
        )
        XCTAssertEqual(
            second.transaction.feeProvenance.gasPrice,
            .manual
        )
    }

    func testAutomaticIntentEditingUnlocksOnlyOnFailureWhileDappIntentStaysEditable() async {
        let automaticStub = ApprovalOperationsStub()
        let automaticCoordinator = makeCoordinator(
            transaction: Self.makeAutomaticIntentTransaction(),
            stub: automaticStub
        )
        XCTAssertFalse(automaticCoordinator.snapshot.canEdit)
        automaticCoordinator.startPreparation(forceGasCheck: false)
        XCTAssertEqual(
            automaticCoordinator.snapshot.phase,
            .preparing
        )
        XCTAssertFalse(automaticCoordinator.snapshot.canEdit)

        let dappStub = ApprovalOperationsStub()
        let dappCoordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(feeSource: .dapp),
            stub: dappStub
        )
        XCTAssertTrue(dappCoordinator.snapshot.canEdit)
        dappCoordinator.startPreparation(forceGasCheck: false)
        XCTAssertFalse(dappCoordinator.snapshot.canEdit)
        dappStub.preparationCalls[0].completion(
            .failure(.gasPriceUnavailable)
        )
        await waitFor { dappCoordinator.snapshot.phase == .failed }
        XCTAssertEqual(dappCoordinator.snapshot.phase, .failed)
        XCTAssertTrue(dappCoordinator.snapshot.canEdit)
    }

    func testUnsafeFeesPreparationFailureAlertOffersEditor() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        coordinator.startPreparation(forceGasCheck: false)

        stub.preparationCalls[0].completion(.failure(.unsafeFees))

        await waitFor { (coordinator.snapshot.phase) == (.failed) }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        await waitFor { recorder.alerts.last != nil }
        let alert = try! XCTUnwrap(recorder.alerts.last)
        guard case .preparationFailure(
            .unsafeFees,
            let forceGasCheck
        ) = alert.kind else {
            return XCTFail("Unexpected alert")
        }
        XCTAssertFalse(forceGasCheck)
        XCTAssertEqual(alert.token.kind, .preparationFailure)
        XCTAssertEqual(alert.presentation.primaryAction.action, .edit)

        coordinator.handleAlert(token: alert.token, action: .edit)
        await waitFor { (recorder.editorRequestCount) == (1) }
        XCTAssertEqual(recorder.editorRequestCount, 1)
        XCTAssertFalse(coordinator.isCurrentAlert(alert.token))
        await waitFor { (coordinator.snapshot.phase) == (.failed) }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
    }

    func testAuthenticatingRejectsLatePreparationUpdateAndEdits() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        await waitFor { stub.preparationCalls.count > 0 }
        let preparation = stub.preparationCalls[0]
        coordinator.approve()
        await waitFor { (coordinator.snapshot.phase) == (.authenticating) }
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)
        let transactionID = coordinator.snapshot.transaction.id
        let snapshotCount = recorder.snapshots.count

        var lateUpdate = preparation.transaction
        lateUpdate.interpretation = "Too late"
        preparation.onUpdate(lateUpdate)

        XCTAssertNil(coordinator.snapshot.transaction.interpretation)

        XCTAssertFalse(
            coordinator.apply(edits: Transaction.Edits(nonce: 1))
        )

        await waitFor { (coordinator.snapshot.phase) == (.authenticating) }
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)
        await waitFor { (coordinator.snapshot.transaction.id) == (transactionID) }
        XCTAssertEqual(
            coordinator.snapshot.transaction.id,
            transactionID
        )
        await waitFor { (recorder.snapshots.count) == (snapshotCount) }
        XCTAssertEqual(recorder.snapshots.count, snapshotCount)
    }

    func testStartPreparationAfterFinishIsNoOp() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        await prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        coordinator.cancel()
        await waitFor { (coordinator.snapshot.phase) == (.finished) }
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        await waitFor { (recorder.completions.count) == (1) }
        XCTAssertEqual(recorder.completions.count, 1)
        let snapshotCount = recorder.snapshots.count

        coordinator.startPreparation(forceGasCheck: false)

        await waitFor { (stub.preparationCalls.count) == (1) }
        XCTAssertEqual(stub.preparationCalls.count, 1)
        await waitFor { (coordinator.snapshot.phase) == (.finished) }
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        await waitFor { (recorder.snapshots.count) == (snapshotCount) }
        XCTAssertEqual(recorder.snapshots.count, snapshotCount)
        await waitFor { (recorder.completions.count) == (1) }
        XCTAssertEqual(recorder.completions.count, 1)
    }

    private func makeCoordinator(
        transaction: Transaction? = nil,
        network: EthereumNetwork? = nil,
        authenticationPolicy: TransactionApprovalAuthenticationPolicy =
            .skipped,
        stub: ApprovalOperationsStub,
        recorder: ApprovalOutputRecorder? = nil
    ) -> TransactionApprovalCoordinator {
        TransactionApprovalCoordinator(
            transaction: transaction ?? Self.makeReadyTransaction(),
            network: network ?? Self.makeNetwork(),
            authenticationPolicy: authenticationPolicy,
            operations: stub.operations,
            onOutput: recorder?.record ?? { _ in }
        )
    }

    private func prepareToReady(
        _ coordinator: TransactionApprovalCoordinator,
        stub: ApprovalOperationsStub,
        estimate: GasService.Estimate? = nil
    ) async {
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)
        if let estimate { call.onFeeEstimate(estimate) }
        call.completion(.success(call.transaction))
        await waitFor { (coordinator.snapshot.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
    }

    private static func makeReadyTransaction(
        id: UUID = UUID(),
        gasPrice: BigUInt = 10,
        feeSource: TransactionFeeSource = .automatic
    ) -> Transaction {
        Transaction(
            id: id,
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: gasPrice),
            preparedFee: .legacy(gasPrice: gasPrice),
            feeSource: feeSource
        )
    }

    private static func makeAutomaticIntentTransaction(
        id: UUID = UUID()
    ) -> Transaction {
        Transaction(
            id: id,
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic
        )
    }

    private static func makeNetwork() -> EthereumNetwork {
        EthereumNetwork(
            chainId: 10,
            name: "Test",
            symbol: "ETH",
            rpcEndpoint: .unauthenticated(
                URL(string: "https://rpc.example")!
            ),
            isTestnet: true,
            mightShowPrice: false,
            explorer: nil
        )
    }

    private static func makeGasInfo() -> GasService.Info {
        GasService.Info(
            recommendedPriorityFee: 20,
            highPriorityFee: 40
        )
    }

    private static func makeEstimate() -> GasService.Estimate {
        GasService.Estimate(
            info: Self.makeGasInfo(),
            nextBaseFee: 100,
            currentBaseFee: 90,
            support: .eip1559,
            gasPrice: nil,
            endpointChainID: 10
        )
    }

    private static func makeUnknownEstimate(
        currentBaseFee: BigUInt? = nil,
        nextBaseFee: BigUInt? = nil
    ) -> GasService.Estimate {
        GasService.Estimate(
            info: nil,
            nextBaseFee: nextBaseFee,
            currentBaseFee: currentBaseFee,
            support: .unknown,
            gasPrice: nil,
            endpointChainID: 10
        )
    }

    private static func makeLegacyEstimate() -> GasService.Estimate {
        GasService.Estimate(
            info: Self.makeGasInfo(),
            nextBaseFee: nil,
            currentBaseFee: nil,
            support: .legacy,
            gasPrice: 100,
            endpointChainID: 10
        )
    }

    private static func makeCatalogHintedNetwork() -> EthereumNetwork {
        let url = URL(string: "https://rpc.example")!
        return EthereumNetwork(
            chainId: 10,
            name: "Test",
            symbol: "ETH",
            rpcEndpoint: .catalog(
                url,
                alchemyNetwork: nil,
                feeMarketHint: EthereumFeeMarketHint(
                    support: .eip1559,
                    checkedAt: ISO8601DateFormatter().string(from: Date()),
                    observedEndpoint: url.absoluteString
                )
            ),
            isTestnet: true,
            mightShowPrice: false,
            explorer: nil
        )
    }

    private func waitFor(_ predicate: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !predicate(), clock.now < deadline { await Task.yield() }
    }

}

@MainActor
private final class ApprovalOperationsStub {
    final class PreparationCall {
        let transaction: Transaction
        let forceGasCheck: Bool
        let cancellation = TestRequestCancellation()
        let continuation: AsyncThrowingStream<TransactionPreparationEvent, Error>.Continuation

        init(
            transaction: Transaction, forceGasCheck: Bool,
            continuation: AsyncThrowingStream<TransactionPreparationEvent, Error>.Continuation
        ) {
            self.transaction = transaction
            self.forceGasCheck = forceGasCheck
            self.continuation = continuation
            let cancellation = cancellation
            continuation.onTermination = { termination in
                if case .cancelled = termination { cancellation.cancel() }
            }
        }

        func onUpdate(_ transaction: Transaction) { continuation.yield(.transactionUpdated(transaction)) }
        func onFeeEstimate(_ estimate: GasService.Estimate) { continuation.yield(.feeEstimate(estimate)) }
        func completion(_ result: Result<Transaction, TransactionPreparationFailure>) {
            switch result {
            case .success(let value): continuation.yield(.ready(value))
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    final class PreflightCall {
        let transaction: Transaction
        let cancellation = TestPreflightResult()
        init(transaction: Transaction) { self.transaction = transaction }
        func completion(_ result: TransactionFeePreflightResult) { cancellation.finish(result) }
    }

    var preparationCalls = [PreparationCall]()
    var preflightCalls = [PreflightCall]()
    var synchronousPreparation: ((PreparationCall) -> Void)?

    var operations: TransactionApprovalOperations {
        TransactionApprovalOperations(
            prepare: { [self] transaction, forceGasCheck, _ in
                AsyncThrowingStream { continuation in
                    let call = PreparationCall(
                        transaction: transaction, forceGasCheck: forceGasCheck, continuation: continuation)
                    preparationCalls.append(call)
                    synchronousPreparation?(call)
                }
            },
            preflight: { [self] transaction, _ in
                let call = PreflightCall(transaction: transaction)
                preflightCalls.append(call)
                return try await call.cancellation.value()
            }
        )
    }
}

private final class TestRequestCancellation: Sendable {
    private let canceled = Mutex(false)
    var isCancelled: Bool { canceled.withLock { $0 } }
    func cancel() { canceled.withLock { $0 = true } }
}

private final class TestPreflightResult: Sendable {
    private struct State {
        var isCancelled = false
        var continuation: CheckedContinuation<TransactionFeePreflightResult, Error>?
        var result: TransactionFeePreflightResult?
    }
    private let state = Mutex(State())
    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func value() async throws -> TransactionFeePreflightResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<TransactionFeePreflightResult, Error>? in
                    if state.isCancelled { return .failure(CancellationError()) }
                    if let result = state.result { return .success(result) }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let continuation = self.state.withLock { state in
                state.isCancelled = true
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func finish(_ result: TransactionFeePreflightResult) {
        let continuation = state.withLock { state in
            guard !state.isCancelled, state.result == nil else {
                return Optional<CheckedContinuation<TransactionFeePreflightResult, Error>>.none
            }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

@MainActor
private final class ApprovalOutputRecorder {
    var snapshots = [TransactionApprovalSnapshot]()
    var estimates = [GasService.Estimate]()
    var authenticationTokens = [TransactionApprovalRequestToken]()
    var alerts = [TransactionApprovalAlertIntent]()
    var editorRequestCount = 0
    var completions = [Transaction?]()

    func record(_ output: TransactionApprovalOutput) {
        switch output {
        case .snapshot(let snapshot):
            snapshots.append(snapshot)
        case .verifiedFeeEstimate(let estimate):
            estimates.append(estimate)
        case .authenticationRequest(let token):
            authenticationTokens.append(token)
        case .alert(let alert):
            alerts.append(alert)
        case .editorRequest:
            editorRequestCount += 1
        case .completion(let transaction):
            completions.append(transaction)
        }
    }
}

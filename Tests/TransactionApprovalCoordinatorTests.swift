// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

@MainActor
final class TransactionApprovalCoordinatorTests: XCTestCase {

    func testPreparationStateRequiresCurrentTerminalSuccess() {
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

    func testPreparationStateSerializesAuthenticationAndPreflight() {
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

    func testPreparationRestartGateCoalescesMutations() {
        var gate = TransactionPreparationRestartGate()

        XCTAssertTrue(gate.recordMutation())
        for _ in 0..<20 {
            XCTAssertFalse(gate.recordMutation())
        }
        XCTAssertTrue(gate.consume())
        XCTAssertFalse(gate.consume())
    }

    func testApproveReturnsWhetherApprovalFlowStarted() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)

        XCTAssertFalse(coordinator.approve())
        prepareToReady(coordinator, stub: stub)
        XCTAssertTrue(coordinator.approve())
        XCTAssertFalse(coordinator.approve())
    }

    func testPreparationTokenIncludesAttemptTransactionAndKind() {
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

    func testNewAttemptCancelsPriorBeforeStartingAndStaleResultCannotClearNewerHandle() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)

        coordinator.startPreparation(forceGasCheck: false)
        let first = stub.preparationCalls[0]
        coordinator.startPreparation(forceGasCheck: true)
        let second = stub.preparationCalls[1]

        XCTAssertTrue(first.cancellation.isCancelled)
        XCTAssertEqual(
            stub.priorPreparationWasCancelledAtStart,
            [true, true]
        )

        var staleUpdate = first.transaction
        staleUpdate.interpretation = "stale"
        first.onUpdate(staleUpdate)
        first.onFeeEstimate(Self.makeEstimate())
        first.completion(.failure(.gasEstimationFailed))
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
        XCTAssertNil(coordinator.snapshot.transaction.interpretation)
        XCTAssertFalse(coordinator.snapshot.hasVerifiedFeeEstimate)
        XCTAssertFalse(second.cancellation.isCancelled)

        coordinator.startPreparation(forceGasCheck: false)
        XCTAssertTrue(second.cancellation.isCancelled)
        XCTAssertFalse(
            stub.preparationCalls[2].cancellation.isCancelled
        )
    }

    func testPreparationUpdateWinsOverTerminalSnapshot() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls[0]

        var updated = call.transaction
        updated.interpretation = "Latest accepted update"
        call.onUpdate(updated)

        var terminal = call.transaction
        terminal.interpretation = "Older terminal snapshot"
        call.completion(.success(terminal))

        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertEqual(
            coordinator.snapshot.transaction.interpretation,
            "Latest accepted update"
        )
    }

    func testLatePreparationUpdateAfterCompletionUpdatesReadySnapshot() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls[0]

        call.completion(.success(call.transaction))
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertTrue(coordinator.snapshot.canApprove)
        XCTAssertFalse(call.cancellation.isCancelled)

        var lateUpdate = call.transaction
        lateUpdate.interpretation = "Late interpretation"
        call.onUpdate(lateUpdate)

        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertEqual(
            coordinator.snapshot.transaction.interpretation,
            "Late interpretation"
        )
        XCTAssertTrue(coordinator.snapshot.canApprove)
    }

    func testLatePreparationUpdateIsIgnoredAfterReadyAdvancesToPreflight() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        let preparation = stub.preparationCalls[0]
        preparation.completion(.success(preparation.transaction))

        coordinator.approve()
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
        XCTAssertEqual(stub.preflightCalls.count, 1)

        var lateUpdate = preparation.transaction
        lateUpdate.interpretation = "Too late"
        preparation.onUpdate(lateUpdate)

        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
        XCTAssertNil(coordinator.snapshot.transaction.interpretation)
    }

    func testSynchronousCompletionCannotRetainOldHandleOrOverwriteReentrantRequest() {
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

        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertTrue(stub.preparationCalls[0].cancellation.isCancelled)
        XCTAssertFalse(stub.preparationCalls[1].cancellation.isCancelled)
        coordinator.startPreparation(forceGasCheck: false)
        XCTAssertTrue(stub.preparationCalls[1].cancellation.isCancelled)
    }

    func testFailureRetryPreservesForcePolicyAndClearsUnverifiedBaseFees() {
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

        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        XCTAssertNil(
            coordinator.snapshot.transaction.currentBaseFeePerGas
        )
        XCTAssertNil(coordinator.snapshot.transaction.nextBaseFeePerGas)
        let alert = try! XCTUnwrap(recorder.alerts.last)
        guard case .preparationFailure(
            .gasEstimationFailed,
            let forceGasCheck
        ) = alert.kind else {
            return XCTFail("Unexpected alert")
        }
        XCTAssertTrue(forceGasCheck)

        coordinator.handleAlert(token: alert.token, action: .retry)
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertTrue(stub.preparationCalls[1].forceGasCheck)
    }

    func testEstimateBeforeFailurePreservesVerifiedBaseFees() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls[0]

        call.onFeeEstimate(Self.makeEstimate())
        call.completion(.failure(.gasEstimationFailed))

        XCTAssertTrue(coordinator.snapshot.hasVerifiedFeeEstimate)
        XCTAssertEqual(
            coordinator.snapshot.transaction.currentBaseFeePerGas,
            90
        )
        XCTAssertEqual(
            coordinator.snapshot.transaction.nextBaseFeePerGas,
            100
        )
    }

    func testEditsInvalidateTransactionAttemptAndDeferredAlert() {
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
        XCTAssertEqual(stub.preparationCalls.count, 1)
    }

    func testRequiredAuthenticationFailureRestoresReady() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)

        coordinator.approve()

        XCTAssertTrue(stub.preparationCalls[0].cancellation.isCancelled)
        let token = try! XCTUnwrap(recorder.authenticationTokens.last)
        XCTAssertEqual(token.kind, .authentication)
        XCTAssertEqual(token.attemptID, coordinator.snapshot.attemptID)
        XCTAssertEqual(
            token.transactionID,
            coordinator.snapshot.transaction.id
        )
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)
        XCTAssertFalse(coordinator.snapshot.allowsMutation)

        coordinator.authenticationCompleted(
            token: token,
            succeeded: false
        )
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertTrue(coordinator.snapshot.canApprove)
    }

    func testRequiredAuthenticationSuccessStartsOnePreflightAndRejectsRepeatedResult() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let token = recorder.authenticationTokens.last!
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

        XCTAssertEqual(stub.preflightCalls.count, 1)
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
    }

    func testCancelWhileAuthenticatingRejectsLateAuthentication() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let token = recorder.authenticationTokens.last!
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)

        coordinator.cancel()
        coordinator.authenticationCompleted(
            token: token,
            succeeded: true
        )

        XCTAssertTrue(stub.preflightCalls.isEmpty)
        XCTAssertEqual(recorder.completions.count, 1)
        XCTAssertNil(recorder.completions[0])
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
    }

    func testFailedAuthenticationTokenCannotAuthorizeRetry() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)

        coordinator.approve()
        let firstToken = recorder.authenticationTokens.last!
        coordinator.authenticationCompleted(
            token: firstToken,
            succeeded: false
        )

        coordinator.approve()
        let secondToken = recorder.authenticationTokens.last!
        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)

        coordinator.authenticationCompleted(
            token: firstToken,
            succeeded: true
        )
        XCTAssertTrue(stub.preflightCalls.isEmpty)
        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)

        coordinator.authenticationCompleted(
            token: secondToken,
            succeeded: true
        )
        XCTAssertEqual(stub.preflightCalls.count, 1)
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
    }

    func testSkippedAuthenticationStartsPreflightDirectly() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .skipped,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)

        coordinator.approve()

        XCTAssertTrue(recorder.authenticationTokens.isEmpty)
        XCTAssertEqual(stub.preflightCalls.count, 1)
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
    }

    func testSafePreflightCompletesExactlyOnceAcrossReentrantAndStaleEvents() {
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
        prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let preflight = stub.preflightCalls[0]
        let result = TransactionFeePreflightResult.safe(
            preflight.transaction,
            Self.makeEstimate()
        )

        preflight.completion(result)
        preflight.completion(result)
        coordinator.cancel()

        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(
            completions[0]?.id,
            preflight.transaction.id
        )
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
    }

    func testPreflightSafeWithUnknownNoDataEstimatePreservesBaseFeesForSend()
        throws {
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
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        coordinator.approve()
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .safe(preflight.transaction, Self.makeUnknownEstimate())
        )

        XCTAssertEqual(recorder.completions.count, 1)
        let completed = try XCTUnwrap(recorder.completions[0])
        XCTAssertEqual(completed.currentBaseFeePerGas, 90)
        XCTAssertEqual(completed.nextBaseFeePerGas, 100)
        XCTAssertTrue(completed.isReadyForApproval(on: network))
    }

    func testPreparationUnknownEstimateAfterEIP1559EstimateKeepsBaseFees() {
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

        XCTAssertEqual(recorder.estimates.count, 2)
        XCTAssertEqual(
            coordinator.snapshot.transaction.currentBaseFeePerGas,
            90
        )
        XCTAssertEqual(
            coordinator.snapshot.transaction.nextBaseFeePerGas,
            100
        )
        call.completion(.success(call.transaction))
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertTrue(
            coordinator.snapshot.transaction.isReadyForApproval(on: network)
        )
    }

    func testPreflightSafeWithUnknownDataEstimateAdoptsObservedBaseFee()
        throws {
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
        coordinator.approve()
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .safe(
                preflight.transaction,
                Self.makeUnknownEstimate(currentBaseFee: 120)
            )
        )

        XCTAssertEqual(recorder.completions.count, 1)
        let completed = try XCTUnwrap(recorder.completions[0])
        XCTAssertEqual(completed.currentBaseFeePerGas, 120)
        XCTAssertNil(completed.nextBaseFeePerGas)
        XCTAssertTrue(completed.isReadyForApproval(on: network))
    }

    func testPreparationLegacyEstimateClearsBaseFees() {
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

    func testWalletManagedUpdateInstallsCanonicalStateAndAcknowledgmentRestarts() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let preflight = stub.preflightCalls[0]
        let updated = Self.makeReadyTransaction(
            id: preflight.transaction.id,
            gasPrice: 99,
            feeSource: .slider
        )

        preflight.completion(
            .walletManagedUpdated(updated, Self.makeEstimate())
        )

        XCTAssertEqual(
            coordinator.snapshot.transaction.preparedFee,
            .legacy(gasPrice: 99)
        )
        XCTAssertEqual(
            coordinator.snapshot.transaction.nextBaseFeePerGas,
            100
        )
        let alert = try! XCTUnwrap(recorder.alerts.last)
        XCTAssertEqual(alert.kind, .feesUpdated)
        XCTAssertTrue(coordinator.isCurrentAlert(alert.token))
        XCTAssertEqual(coordinator.snapshot.phase, .reviewingFees)

        preflight.completion(.safe(updated, Self.makeEstimate()))
        XCTAssertTrue(recorder.completions.isEmpty)
        XCTAssertEqual(coordinator.snapshot.phase, .reviewingFees)

        coordinator.handleAlert(
            token: alert.token,
            action: .acknowledge
        )

        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertFalse(stub.preparationCalls[1].forceGasCheck)
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
        XCTAssertFalse(coordinator.isCurrentAlert(alert.token))

        preflight.completion(
            .safe(preflight.transaction, Self.makeEstimate())
        )
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
        XCTAssertEqual(
            coordinator.snapshot.transaction.preparedFee,
            .legacy(gasPrice: 99)
        )
        XCTAssertTrue(recorder.completions.isEmpty)
        XCTAssertFalse(stub.preparationCalls[1].cancellation.isCancelled)
    }

    func testUnsafePreflightAdvancesEditingAttemptBeforeAlert() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        let preflightAttempt = coordinator.snapshot.attemptID
        coordinator.approve()
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .userControlledUnsafe(
                preflight.transaction,
                Self.makeEstimate()
            )
        )

        let alert = try! XCTUnwrap(recorder.alerts.last)
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
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
        XCTAssertEqual(recorder.editorRequestCount, 1)
    }

    func testUnavailablePreflightFailsAndEmitsRetryableAlert() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .unavailable(preflight.transaction, Self.makeEstimate())
        )

        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        let alert = try! XCTUnwrap(recorder.alerts.last)
        XCTAssertEqual(alert.kind, .unavailableFees)
        coordinator.handleAlert(token: alert.token, action: .retry)
        XCTAssertEqual(stub.preparationCalls.count, 2)
    }

    func testSliderMutationsCoalesceAndNoninteractiveMutationRestarts() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        prepareToReady(coordinator, stub: stub)
        let readyAttempt = coordinator.snapshot.attemptID
        let info = Self.makeGasInfo()

        coordinator.beginSliderInteraction()
        coordinator.beginSliderInteraction()
        XCTAssertTrue(
            coordinator.setFeeForSpeed(
                value: 100,
                inRelationTo: info
            )
        )
        let editingAttempt = coordinator.snapshot.attemptID
        XCTAssertEqual(editingAttempt, readyAttempt + 1)
        XCTAssertTrue(
            coordinator.setFeeForSpeed(
                value: 50,
                inRelationTo: info
            )
        )
        XCTAssertEqual(coordinator.snapshot.attemptID, editingAttempt)
        XCTAssertTrue(coordinator.endSliderInteraction())
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertFalse(coordinator.endSliderInteraction())

        stub.preparationCalls[1].completion(
            .success(stub.preparationCalls[1].transaction)
        )
        XCTAssertTrue(
            coordinator.setFeeForSpeed(
                value: 0,
                inRelationTo: info
            )
        )
        XCTAssertEqual(stub.preparationCalls.count, 3)
        XCTAssertEqual(coordinator.snapshot.phase, .preparing)
    }

    func testCancelledSliderEndConsumesPendingMutationWithoutRestart() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        prepareToReady(coordinator, stub: stub)

        coordinator.beginSliderInteraction()
        XCTAssertTrue(
            coordinator.setFeeForSpeed(
                value: 100,
                inRelationTo: Self.makeGasInfo()
            )
        )
        XCTAssertTrue(
            coordinator.endSliderInteraction(cancelled: true)
        )
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertFalse(coordinator.endSliderInteraction())
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
    }

    func testFailedAutomaticFeePreparationUnlocksManualFeeEditingAndRestart() {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeAutomaticIntentTransaction(),
            stub: stub
        )
        coordinator.startPreparation(forceGasCheck: false)
        let first = stub.preparationCalls[0]

        first.completion(.failure(.gasPriceUnavailable))

        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        XCTAssertTrue(coordinator.snapshot.canEdit)
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
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
        XCTAssertFalse(first.cancellation.isCancelled)

        coordinator.startPreparation(forceGasCheck: true)
        XCTAssertEqual(stub.preparationCalls.count, 2)
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

    func testAutomaticIntentEditingUnlocksOnlyOnFailureWhileDappIntentStaysEditable() {
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
        XCTAssertEqual(dappCoordinator.snapshot.phase, .failed)
        XCTAssertTrue(dappCoordinator.snapshot.canEdit)
    }

    func testUnsafeFeesPreparationFailureAlertOffersEditor() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            stub: stub,
            recorder: recorder
        )
        coordinator.startPreparation(forceGasCheck: false)

        stub.preparationCalls[0].completion(.failure(.unsafeFees))

        XCTAssertEqual(coordinator.snapshot.phase, .failed)
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
        XCTAssertEqual(recorder.editorRequestCount, 1)
        XCTAssertFalse(coordinator.isCurrentAlert(alert.token))
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
    }

    func testAuthenticatingRejectsLatePreparationUpdateAndEdits() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        let preparation = stub.preparationCalls[0]
        coordinator.approve()
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

        XCTAssertEqual(coordinator.snapshot.phase, .authenticating)
        XCTAssertEqual(
            coordinator.snapshot.transaction.id,
            transactionID
        )
        XCTAssertEqual(recorder.snapshots.count, snapshotCount)
    }

    func testStartPreparationAfterFinishIsNoOp() {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalOutputRecorder()
        let coordinator = makeCoordinator(
            authenticationPolicy: .required,
            stub: stub,
            recorder: recorder
        )
        prepareToReady(coordinator, stub: stub)
        coordinator.approve()
        coordinator.cancel()
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        XCTAssertEqual(recorder.completions.count, 1)
        let snapshotCount = recorder.snapshots.count

        coordinator.startPreparation(forceGasCheck: false)

        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        XCTAssertEqual(recorder.snapshots.count, snapshotCount)
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
        stub: ApprovalOperationsStub
    ) {
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)
        call.completion(.success(call.transaction))
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

}

private final class ApprovalOperationsStub {

    final class PreparationCall {
        let transaction: Transaction
        let forceGasCheck: Bool
        let cancellation: EthereumRequestCancellation
        let onUpdate: (Transaction) -> Void
        let onFeeEstimate: (GasService.Estimate) -> Void
        let completion: (
            Result<Transaction, TransactionPreparationFailure>
        ) -> Void

        init(
            transaction: Transaction,
            forceGasCheck: Bool,
            cancellation: EthereumRequestCancellation,
            onUpdate: @escaping (Transaction) -> Void,
            onFeeEstimate: @escaping (GasService.Estimate) -> Void,
            completion: @escaping (
                Result<Transaction, TransactionPreparationFailure>
            ) -> Void
        ) {
            self.transaction = transaction
            self.forceGasCheck = forceGasCheck
            self.cancellation = cancellation
            self.onUpdate = onUpdate
            self.onFeeEstimate = onFeeEstimate
            self.completion = completion
        }
    }

    final class PreflightCall {
        let transaction: Transaction
        let cancellation: EthereumRequestCancellation
        let completion: (TransactionFeePreflightResult) -> Void

        init(
            transaction: Transaction,
            cancellation: EthereumRequestCancellation,
            completion: @escaping (TransactionFeePreflightResult) -> Void
        ) {
            self.transaction = transaction
            self.cancellation = cancellation
            self.completion = completion
        }
    }

    var preparationCalls = [PreparationCall]()
    var preflightCalls = [PreflightCall]()
    var priorPreparationWasCancelledAtStart = [Bool]()
    var synchronousPreparation: ((PreparationCall) -> Void)?

    var operations: TransactionApprovalOperations {
        TransactionApprovalOperations(
            prepare: {
                [unowned self]
                transaction,
                forceGasCheck,
                _,
                onUpdate,
                onFeeEstimate,
                completion in
                priorPreparationWasCancelledAtStart.append(
                    preparationCalls.last?.cancellation.isCancelled ?? true
                )
                let call = PreparationCall(
                    transaction: transaction,
                    forceGasCheck: forceGasCheck,
                    cancellation: EthereumRequestCancellation(),
                    onUpdate: onUpdate,
                    onFeeEstimate: onFeeEstimate,
                    completion: completion
                )
                preparationCalls.append(call)
                synchronousPreparation?(call)
                return call.cancellation
            },
            preflight: {
                [unowned self] transaction, _, completion in
                let call = PreflightCall(
                    transaction: transaction,
                    cancellation: EthereumRequestCancellation(),
                    completion: completion
                )
                preflightCalls.append(call)
                return call.cancellation
            }
        )
    }

}

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

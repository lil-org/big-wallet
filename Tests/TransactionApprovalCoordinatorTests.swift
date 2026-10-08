// ∅ 2026 lil org

import XCTest
import Synchronization
#if os(macOS)
import AppKit
#endif
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

    func testPreparationStateSerializesReservationAndPreflight() async {
        let transactionID = UUID()
        var state = TransactionPreparationState()
        let preparedAttempt = state.beginPreparation(for: transactionID)
        XCTAssertTrue(state.markReady(attemptID: preparedAttempt, transactionID: transactionID))
        XCTAssertNil(state.beginPreflight(for: transactionID))
        let first = state.reserveForPreflight(for: transactionID)!
        XCTAssertEqual(first, preparedAttempt + 1)
        XCTAssertFalse(state.allowsMutation)
        XCTAssertTrue(state.restoreReady(attemptID: first, transactionID: transactionID))
        XCTAssertNil(state.beginPreflight(for: transactionID))
        let second = state.reserveForPreflight(for: transactionID)!
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(state.beginPreflight(for: transactionID), second)
        XCTAssertTrue(state.beginUnsafeFeeEditing(attemptID: second, transactionID: transactionID))
        XCTAssertEqual(state.phase, .editing)
        XCTAssertEqual(state.attemptID, second + 1)
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

    func testReservationRequiresReadyStateAndRejectsDuplicates() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        XCTAssertNil(coordinator.reserveForPreflight())
        await prepareToReady(coordinator, stub: stub)
        XCTAssertNotNil(coordinator.reserveForPreflight())
        XCTAssertNil(coordinator.reserveForPreflight())
        XCTAssertEqual(coordinator.snapshot.phase, .reserved)
        XCTAssertFalse(coordinator.snapshot.canApprove)
    }

    func testPreparationTokenIncludesAttemptTransactionAndKind() async {
        let transaction = Self.makeReadyTransaction()
        var reducer = TransactionApprovalReducer(
            transaction: transaction,
            network: Self.makeNetwork(),
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

    func testReducerPublishesFrozenAndReleasedQuotesWithoutCoordinatorEffects() throws {
        var transaction = Self.makeReadyTransaction(gasPrice: 120)
        transaction.currentBaseFeePerGas = 100
        var reducer = TransactionApprovalReducer(
            transaction: transaction,
            network: Self.makeNetwork(),
        )
        let preparation = reducer.reduce(.startPreparation(forceGasCheck: false))
        guard case .runPreparation(let token, _, _) = preparation.last else {
            return XCTFail("Expected a preparation effect")
        }
        let initial = try onlySnapshot(in: preparation)
        XCTAssertTrue(initial.hasGasSpeedInfo)
        XCTAssertEqual(initial.speedPriorityFeePerGas, 20)
        XCTAssertEqual(initial.gasSliderPosition, GasSpeedConfiguration.recommendedSliderPosition)

        _ = reducer.reduce(.preparationEstimate(token, Self.makeEstimate()))
        XCTAssertTrue(reducer.reduce(.sliderInteractionBegan).isEmpty)
        let newInfo = GasService.Info(recommendedPriorityFee: 100, highPriorityFee: 200)
        let frozen = try onlySnapshot(in: reducer.reduce(.preparationEstimate(
            token, .init(info: newInfo, nextBaseFee: 100, support: .eip1559)
        )))
        XCTAssertTrue(frozen.hasVerifiedFeeEstimate)
        XCTAssertEqual(frozen.gasSliderPosition, initial.gasSliderPosition)
        XCTAssertEqual(frozen.speedPriorityFeePerGas, 20)
        XCTAssertEqual(frozen.transaction.feeProvenance, transaction.feeProvenance)

        let release = reducer.reduce(.sliderInteractionEnded(cancelled: false))
        XCTAssertEqual(release.count, 1)
        let released = try onlySnapshot(in: release)
        XCTAssertEqual(released.gasSliderPosition, transaction.currentFeeInRelationTo(info: newInfo))
        XCTAssertEqual(released.transaction.id, transaction.id)
        XCTAssertEqual(released.transaction.preparedFee, transaction.preparedFee)
        XCTAssertEqual(released.transaction.feeProvenance, transaction.feeProvenance)
        XCTAssertEqual(released.attemptID, token.attemptID)
        XCTAssertEqual(frozen.gasSliderPosition, initial.gasSliderPosition)
        XCTAssertTrue(reducer.reduce(.sliderInteractionEnded(cancelled: false)).isEmpty)
    }

    func testReducerOneShotSelectionFreezesNewQuoteAndRejectsStaleEstimate() throws {
        var transaction = Self.makeReadyTransaction(gasPrice: 101)
        transaction.currentBaseFeePerGas = 100
        var reducer = TransactionApprovalReducer(
            transaction: transaction,
            network: Self.makeNetwork(),
        )
        let firstPreparation = reducer.reduce(.startPreparation(forceGasCheck: false))
        guard case .runPreparation(let firstToken, _, _) = firstPreparation.last else {
            return XCTFail("Expected a preparation effect")
        }
        let initialInfo = GasService.Info(recommendedPriorityFee: 1, highPriorityFee: 2)
        _ = reducer.reduce(.preparationEstimate(firstToken, .init(info: initialInfo, nextBaseFee: 100)))
        _ = reducer.reduce(.preparationResult(firstToken, .success(transaction)))

        let selection = reducer.reduce(.setFeeForSpeed(50))
        guard case .runPreparation(let nextToken, _, _) = selection.last else {
            return XCTFail("Expected one-shot selection to start preparation")
        }
        let selected = try onlySnapshot(in: selection)
        XCTAssertEqual(selected.gasSliderPosition, 50)
        XCTAssertEqual(selected.transaction.feeProvenance.gasPrice, .slider)
        XCTAssertEqual(selected.speedPriorityFeePerGas, 1)
        XCTAssertNotEqual(nextToken, firstToken)

        let newInfo = GasService.Info(recommendedPriorityFee: 100, highPriorityFee: 200)
        let newEstimate = GasService.Estimate(info: newInfo, nextBaseFee: 100)
        XCTAssertTrue(reducer.reduce(.preparationEstimate(firstToken, newEstimate)).isEmpty)
        XCTAssertFalse(reducer.snapshot.hasVerifiedFeeEstimate)
        XCTAssertEqual(reducer.snapshot.gasSliderPosition, 50)

        let pending = try onlySnapshot(in: reducer.reduce(.preparationEstimate(nextToken, newEstimate)))
        XCTAssertEqual(pending.gasSliderPosition, 50)
        XCTAssertEqual(pending.transaction.preparedFee, selected.transaction.preparedFee)
        let release = reducer.reduce(.sliderInteractionEnded(cancelled: false))
        XCTAssertEqual(release.count, 1)
        let released = try onlySnapshot(in: release)
        XCTAssertEqual(released.gasSliderPosition, released.transaction.currentFeeInRelationTo(info: newInfo))
        XCTAssertEqual(released.attemptID, nextToken.attemptID)
        XCTAssertEqual(released.transaction.feeProvenance, selected.transaction.feeProvenance)
        XCTAssertEqual(pending.gasSliderPosition, 50)
    }

    func testReducerManualEditsPublishFallbackAndNonceOnlyEditsRetainIt() throws {
        var transaction = Self.makeReadyTransaction(gasPrice: 120)
        transaction.currentBaseFeePerGas = 100
        var reducer = TransactionApprovalReducer(
            transaction: transaction,
            network: Self.makeNetwork(),
        )
        let preparation = reducer.reduce(.startPreparation(forceGasCheck: false))
        guard case .runPreparation(let token, _, _) = preparation.last else {
            return XCTFail("Expected a preparation effect")
        }
        _ = reducer.reduce(.preparationResult(token, .success(transaction)))

        let edited = try onlySnapshot(in: reducer.reduce(.applyEdits(.init(gasPrice: 140))))
        XCTAssertEqual(edited.phase, .editing)
        XCTAssertTrue(edited.hasGasSpeedInfo)
        XCTAssertEqual(edited.speedPriorityFeePerGas, 40)
        XCTAssertEqual(edited.gasSliderPosition, GasSpeedConfiguration.recommendedSliderPosition)
        XCTAssertEqual(edited.transaction.feeProvenance.gasPrice, .manual)

        let nonceEdited = try onlySnapshot(in: reducer.reduce(.applyEdits(.init(nonce: 1))))
        XCTAssertEqual(nonceEdited.transaction.decimalNonceString, "1")
        XCTAssertEqual(nonceEdited.transaction.feeProvenance, edited.transaction.feeProvenance)
        XCTAssertEqual(nonceEdited.gasSliderPosition, edited.gasSliderPosition)
        XCTAssertEqual(nonceEdited.speedPriorityFeePerGas, edited.speedPriorityFeePerGas)
        XCTAssertTrue(reducer.reduce(.applyEdits(.init())).isEmpty)
        XCTAssertEqual(reducer.snapshot.transaction.id, nonceEdited.transaction.id)
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

        let preflightTask = startPreflight(coordinator)
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
        preflightTask.cancel()
        _ = await preflightTask.value
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
            operations: stub.operations
        ) { snapshot in
            guard snapshot.phase == .ready,
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
        var transaction = Self.makeReadyTransaction()
        transaction.currentBaseFeePerGas = 11
        transaction.nextBaseFeePerGas = 12
        let coordinator = makeCoordinator(transaction: transaction, stub: stub)
        coordinator.startPreparation(forceGasCheck: true)
        stub.preparationCalls[0].completion(.failure(.gasEstimationFailed))
        await waitFor { coordinator.snapshot.phase == .failed }
        XCTAssertNil(coordinator.snapshot.transaction.currentBaseFeePerGas)
        XCTAssertNil(coordinator.snapshot.transaction.nextBaseFeePerGas)
        XCTAssertEqual(coordinator.snapshot.notice, .preparationFailed(.gasEstimationFailed))
        XCTAssertTrue(coordinator.snapshot.canRetryPreparation)
        XCTAssertTrue(coordinator.retryPreparation())
        XCTAssertFalse(coordinator.retryPreparation())
        XCTAssertNil(coordinator.snapshot.notice)
        XCTAssertEqual(stub.preparationCalls.count, 2)
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

    func testEditsInvalidateTransactionAttemptAndClearRecoveryNotice() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        stub.preparationCalls[0].completion(.failure(.gasEstimationFailed))
        await waitFor { coordinator.snapshot.notice != nil }
        let oldTransactionID = coordinator.snapshot.transaction.id
        let oldAttemptID = coordinator.snapshot.attemptID
        XCTAssertTrue(coordinator.apply(edits: Transaction.Edits(nonce: 1)))
        XCTAssertNotEqual(coordinator.snapshot.transaction.id, oldTransactionID)
        XCTAssertGreaterThan(coordinator.snapshot.attemptID, oldAttemptID)
        XCTAssertNil(coordinator.snapshot.notice)
        XCTAssertFalse(coordinator.retryPreparation())
        XCTAssertEqual(stub.preparationCalls.count, 1)
    }

    func testReleasingReservationRestoresReadyWithoutPreflight() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        await waitFor { stub.preparationCalls[0].cancellation.isCancelled }
        XCTAssertFalse(coordinator.snapshot.allowsMutation)
        XCTAssertTrue(coordinator.releaseReservation(reservation))
        XCTAssertFalse(coordinator.releaseReservation(reservation))
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertTrue(coordinator.snapshot.canApprove)
        XCTAssertTrue(stub.preflightCalls.isEmpty)
    }

    func testReservationStartsOnePreflightAndRejectsDuplicateCalls() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        XCTAssertTrue(stub.preflightCalls.isEmpty)
        let task = Task { await coordinator.preflight(reservation) }
        await waitFor { stub.preflightCalls.count == 1 }
        guard case .invalidated = await coordinator.preflight(reservation) else {
            return XCTFail("A consumed reservation must not start another preflight")
        }
        let cancelledDuplicate = Task { await coordinator.preflight(reservation) }
        cancelledDuplicate.cancel()
        guard case .invalidated = await cancelledDuplicate.value else {
            return XCTFail("A cancelled duplicate must be rejected")
        }
        XCTAssertEqual(coordinator.snapshot.phase, .preflighting)
        XCTAssertFalse(coordinator.releaseReservation(reservation))
        let call = stub.preflightCalls[0]
        call.completion(.safe(call.transaction, Self.makeEstimate()))
        guard case .approved = await task.value else { return XCTFail("Expected the original preflight") }
        XCTAssertEqual(stub.preflightCalls.count, 1)
    }

    func testInvalidationRejectsReservedTransactionBeforePreflight() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        coordinator.invalidate()
        guard case .invalidated = await coordinator.preflight(reservation) else { return XCTFail("Expected invalidation") }
        XCTAssertTrue(stub.preflightCalls.isEmpty)
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
    }

    func testReleasedReservationCannotAuthorizeFreshAttempt() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let first = try XCTUnwrap(coordinator.reserveForPreflight())
        XCTAssertTrue(coordinator.releaseReservation(first))
        let second = try XCTUnwrap(coordinator.reserveForPreflight())
        XCTAssertNotEqual(first, second)
        guard case .invalidated = await coordinator.preflight(first) else { return XCTFail("Expected stale reservation") }
        XCTAssertEqual(coordinator.snapshot.phase, .reserved)
        XCTAssertTrue(stub.preflightCalls.isEmpty)
        let task = Task { await coordinator.preflight(second) }
        await waitFor { stub.preflightCalls.count == 1 }
        let call = stub.preflightCalls[0]
        call.completion(.safe(call.transaction, Self.makeEstimate()))
        guard case .approved = await task.value else { return XCTFail("Expected fresh preflight") }
    }

    func testCancelledPreflightSettlesBeforeUncooperativeOperation() async throws {
        let stub = ApprovalOperationsStub()
        var continuation: CheckedContinuation<TransactionFeePreflightResult, Never>?
        let coordinator = TransactionApprovalCoordinator(
            transaction: Self.makeReadyTransaction(), network: Self.makeNetwork(),
            operations: .init(prepare: stub.operations.prepare, preflight: { _, _ in
                await withCheckedContinuation { continuation = $0 }
            })
        )
        await prepareToReady(coordinator, stub: stub)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        let task = Task { await coordinator.preflight(reservation) }
        await waitFor { continuation != nil }
        task.cancel()
        guard case .invalidated = await task.value else { return XCTFail("Cancellation must settle the waiter") }
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        continuation?.resume(returning: .safe(Self.makeReadyTransaction(), Self.makeEstimate()))
        await Task.yield()
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        XCTAssertNil(coordinator.snapshot.notice)
    }

    func testOperationCancellationErrorOffersRecoveryWithoutCancellingCaller() async {
        let stub = ApprovalOperationsStub()
        let coordinator = TransactionApprovalCoordinator(
            transaction: Self.makeReadyTransaction(), network: Self.makeNetwork(),
            operations: .init(prepare: stub.operations.prepare, preflight: { _, _ in
                throw CancellationError()
            })
        )
        await prepareToReady(coordinator, stub: stub)
        let task = startPreflight(coordinator)
        guard case .reviewRequired = await task.value else { return XCTFail("Operation failure must offer recovery") }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        XCTAssertEqual(coordinator.snapshot.notice, .feesUnavailable)
        XCTAssertTrue(coordinator.snapshot.canRetryPreparation)
        XCTAssertFalse(task.isCancelled)
        XCTAssertTrue(coordinator.retryPreparation())
    }

    func testCompletedPreflightInvalidationWinsBeforeCallerResumes() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        var didInvalidate = false
        coordinator.onSnapshot = { snapshot in
            guard snapshot.phase == .finished, !didInvalidate else { return }
            didInvalidate = true
            coordinator.invalidate()
        }
        let task = Task { await coordinator.preflight(reservation) }
        await waitFor { stub.preflightCalls.count == 1 }
        let call = stub.preflightCalls[0]
        call.completion(.safe(call.transaction, Self.makeEstimate()))
        call.completion(.safe(call.transaction, Self.makeEstimate()))
        guard case .invalidated = await task.value else { return XCTFail("Invalidation must fence a finished preflight") }
        XCTAssertTrue(didInvalidate)
        let finishedGeneration = coordinator.snapshot.attemptID
        coordinator.invalidate()
        XCTAssertGreaterThan(coordinator.snapshot.attemptID, finishedGeneration)
    }

    func testPreflightSafeWithUnknownNoDataEstimatePreservesBaseFeesForSend()
        async throws
    {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalSnapshotRecorder()
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
        let preflightTask = startPreflight(coordinator)
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = stub.preflightCalls[0]

        preflight.completion(
            .safe(preflight.transaction, Self.makeUnknownEstimate())
        )

        guard case .approved(let completed) = await preflightTask.value else {
            return XCTFail("Expected a completed transaction")
        }
        XCTAssertEqual(completed.currentBaseFeePerGas, 90)
        XCTAssertEqual(completed.nextBaseFeePerGas, 100)
        XCTAssertTrue(completed.isReadyForApproval(on: network))
    }

    func testPreparationUnknownEstimateAfterEIP1559EstimateKeepsBaseFees() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalSnapshotRecorder()
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

        await waitFor { recorder.snapshots.filter(\.hasVerifiedFeeEstimate).count == 2 }
        XCTAssertEqual(recorder.snapshots.filter(\.hasVerifiedFeeEstimate).count, 2)
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
        let recorder = ApprovalSnapshotRecorder()
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
        let preflightTask = startPreflight(coordinator)
        await waitFor { stub.preflightCalls.count > 0 }
        let preflight = try XCTUnwrap(stub.preflightCalls.first)

        preflight.completion(
            .safe(
                preflight.transaction,
                Self.makeUnknownEstimate(currentBaseFee: 120)
            )
        )

        guard case .approved(let completed) = await preflightTask.value else {
            return XCTFail("Expected a completed transaction")
        }
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

    func testWalletManagedUpdateRequiresFreshExplicitApprovalWithoutAcknowledgment() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let first = try XCTUnwrap(coordinator.reserveForPreflight())
        let task = Task { await coordinator.preflight(first) }
        await waitFor { stub.preflightCalls.count == 1 }
        var updated = stub.preflightCalls[0].transaction
        updated.replacePreparedFee(.legacy(gasPrice: 200), provenance: .init(gasPrice: .automatic))
        stub.preflightCalls[0].completion(.walletManagedUpdated(updated, Self.makeEstimate()))
        guard case .reviewRequired = await task.value else { return XCTFail("Changed fees must return to review") }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertEqual(coordinator.snapshot.notice, .feesUpdated)
        XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, updated.preparedFee)
        XCTAssertTrue(coordinator.snapshot.canApprove)
        XCTAssertFalse(coordinator.snapshot.canRetryPreparation)
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertEqual(stub.preflightCalls.count, 1)
        guard case .invalidated = await coordinator.preflight(first) else { return XCTFail("The previous approval cannot accept changed fees") }
        let released = try XCTUnwrap(coordinator.reserveForPreflight())
        XCTAssertTrue(coordinator.releaseReservation(released))
        XCTAssertEqual(coordinator.snapshot.notice, .feesUpdated)
        XCTAssertTrue(coordinator.snapshot.canApprove)
        let second = try XCTUnwrap(coordinator.reserveForPreflight())
        XCTAssertNotEqual(first, second)
        let retry = Task { await coordinator.preflight(second) }
        await waitFor { stub.preflightCalls.count == 2 }
        XCTAssertEqual(stub.preflightCalls[1].transaction.preparedFee, updated.preparedFee)
        stub.preflightCalls[1].completion(.safe(updated, Self.makeEstimate()))
        guard case .approved = await retry.value else { return XCTFail("Expected explicit fresh approval") }
        XCTAssertNil(coordinator.snapshot.notice)
    }

    func testUnsafePreflightOffersInlineEditingAndInvalidatesReservation() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        let task = Task { await coordinator.preflight(reservation) }
        await waitFor { stub.preflightCalls.count == 1 }
        let call = stub.preflightCalls[0]
        call.completion(.userControlledUnsafe(call.transaction, Self.makeEstimate()))
        guard case .reviewRequired = await task.value else { return XCTFail("Expected fee correction") }
        XCTAssertEqual(coordinator.snapshot.notice, .unsafeFees)
        XCTAssertEqual(coordinator.snapshot.phase, .editing)
        XCTAssertGreaterThan(coordinator.snapshot.attemptID, reservation.attemptID)
        XCTAssertTrue(coordinator.snapshot.canEdit)
        XCTAssertFalse(coordinator.snapshot.canApprove)
        XCTAssertFalse(coordinator.snapshot.canRetryPreparation)
        XCTAssertEqual(coordinator.snapshot.notice?.message, Strings.unsafeFeesEdit)
    }

    func testUnavailablePreflightOffersInlineRetryWithoutApproval() async throws {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let task = startPreflight(coordinator)
        await waitFor { stub.preflightCalls.count == 1 }
        let call = stub.preflightCalls[0]
        call.completion(.unavailable(call.transaction, Self.makeEstimate()))
        guard case .reviewRequired = await task.value else { return XCTFail("Expected retryable fee failure") }
        XCTAssertEqual(coordinator.snapshot.phase, .failed)
        XCTAssertEqual(coordinator.snapshot.notice, .feesUnavailable)
        XCTAssertFalse(coordinator.snapshot.canApprove)
        XCTAssertTrue(coordinator.snapshot.canRetryPreparation)
        XCTAssertTrue(coordinator.retryPreparation())
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertFalse(stub.preparationCalls[1].forceGasCheck)
        XCTAssertNil(coordinator.snapshot.notice)
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

    func testQuantizedSliderMovePublishesPositionWithoutChangingFeeOrRestarting() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(
            transaction: Self.makeReadyTransaction(gasPrice: 101),
            stub: stub
        )
        let info = GasService.Info(recommendedPriorityFee: 1, highPriorityFee: 2)
        await prepareToReady(coordinator, stub: stub, estimate: .init(info: info, nextBaseFee: 100))
        coordinator.beginSliderInteraction()
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 50))
        XCTAssertTrue(coordinator.endSliderInteraction())
        await waitFor { stub.preparationCalls.count == 2 }
        let preparation = stub.preparationCalls[1]
        preparation.completion(.success(preparation.transaction))
        await waitFor { coordinator.snapshot.phase == .ready }

        let selected = coordinator.snapshot
        var displayedSnapshot = selected
        var publishedPositions = [Double]()
        coordinator.onSnapshot = { snapshot in
            displayedSnapshot = snapshot
            publishedPositions.append(snapshot.gasSliderPosition)
        }
        coordinator.beginSliderInteraction()

        XCTAssertFalse(coordinator.setFeeForSpeed(value: 60))
        XCTAssertFalse(coordinator.endSliderInteraction())

        XCTAssertEqual(publishedPositions, [60])
        XCTAssertEqual(displayedSnapshot.gasSliderPosition, 60)
        XCTAssertEqual(displayedSnapshot.transaction.id, selected.transaction.id)
        XCTAssertEqual(displayedSnapshot.transaction.preparedFee, selected.transaction.preparedFee)
        XCTAssertEqual(displayedSnapshot.transaction.feeProvenance, selected.transaction.feeProvenance)
        XCTAssertEqual(displayedSnapshot.phase, .ready)
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertFalse(coordinator.setFeeForSpeed(value: 60))
        XCTAssertFalse(coordinator.endSliderInteraction())
        XCTAssertEqual(publishedPositions, [60])
        XCTAssertEqual(stub.preparationCalls.count, 2)
    }

    func testSliderWithoutMovementAppliesPendingQuoteAndPublishesWithoutRestart() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(transaction: Self.makeReadyTransaction(gasPrice: 120), stub: stub)
        let firstQuote = expectation(description: "initial quote received")
        let secondQuote = expectation(description: "pending quote received")
        var quoteCount = 0
        coordinator.onSnapshot = { snapshot in
            if snapshot.hasVerifiedFeeEstimate {
                quoteCount += 1
                (quoteCount == 1 ? firstQuote : secondQuote).fulfill()
            }
        }
        coordinator.startPreparation(forceGasCheck: false)
        let preparation = stub.preparationCalls[0]
        preparation.onFeeEstimate(Self.makeEstimate())
        await fulfillment(of: [firstQuote], timeout: 2)
        let transaction = coordinator.snapshot.transaction
        let initialPosition = coordinator.snapshot.gasSliderPosition
        let newInfo = GasService.Info(recommendedPriorityFee: 100, highPriorityFee: 200)
        coordinator.beginSliderInteraction()
        preparation.onFeeEstimate(.init(info: newInfo, nextBaseFee: 100))
        await fulfillment(of: [secondQuote], timeout: 2)
        XCTAssertEqual(coordinator.snapshot.gasSliderPosition, initialPosition)
        var publishedPositions = [Double]()
        coordinator.onSnapshot = { snapshot in
            publishedPositions.append(snapshot.gasSliderPosition)
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
        coordinator.onSnapshot = { snapshot in
            positionsDuringPreparation.append(snapshot.gasSliderPosition)
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
        coordinator.onSnapshot = { _ in }
        XCTAssertFalse(coordinator.endSliderInteraction())
        await waitFor {
            (coordinator.snapshot.gasSliderPosition) == (coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo))
        }
        XCTAssertEqual(
            coordinator.snapshot.gasSliderPosition,
            coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo)
        )
        await waitFor { (stub.preparationCalls.count) == (2) }
        XCTAssertEqual(stub.preparationCalls.count, 2)
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 100))
        await waitFor { (coordinator.snapshot.speedPriorityFeePerGas) == (100) }
        XCTAssertEqual(coordinator.snapshot.speedPriorityFeePerGas, 100)
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
            (coordinator.snapshot.gasSliderPosition) == (coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo))
        }
        XCTAssertEqual(
            coordinator.snapshot.gasSliderPosition,
            coordinator.snapshot.transaction.currentFeeInRelationTo(info: newInfo)
        )
        coordinator.beginSliderInteraction()
        XCTAssertTrue(coordinator.setFeeForSpeed(value: 100))
        await waitFor { (coordinator.snapshot.speedPriorityFeePerGas) == (100) }
        XCTAssertEqual(coordinator.snapshot.speedPriorityFeePerGas, 100)
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
        coordinator.onSnapshot = { snapshot in
            XCTAssertEqual(snapshot.transaction.preparedFee, .legacy(gasPrice: 140))
            XCTAssertEqual(snapshot.speedPriorityFeePerGas, 40)
            positions.append(snapshot.gasSliderPosition)
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
        coordinator.onSnapshot = { _ in }
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
        await waitFor { (coordinator.snapshot.gasSliderPosition) == (50) }
        XCTAssertEqual(coordinator.snapshot.gasSliderPosition, 50)
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

    func testUnsafeFeesPreparationFailureOffersInlineEditor() async {
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(stub: stub)
        coordinator.startPreparation(forceGasCheck: false)
        stub.preparationCalls[0].completion(.failure(.unsafeFees))
        await waitFor { coordinator.snapshot.phase == .failed }
        XCTAssertEqual(coordinator.snapshot.notice, .preparationFailed(.unsafeFees))
        XCTAssertEqual(coordinator.snapshot.notice?.title, Strings.unsafeFees)
        XCTAssertEqual(coordinator.snapshot.notice?.message, Strings.unsafeFeesEdit)
        XCTAssertTrue(coordinator.snapshot.canEdit)
        XCTAssertFalse(coordinator.snapshot.canRetryPreparation)
        XCTAssertFalse(coordinator.retryPreparation())
        XCTAssertTrue(coordinator.apply(edits: .init(gasPrice: 200)))
        XCTAssertNil(coordinator.snapshot.notice)
    }

    func testReservedTransactionRejectsLatePreparationAndMutation() async throws {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalSnapshotRecorder()
        let coordinator = makeCoordinator(stub: stub, recorder: recorder)
        await prepareToReady(coordinator, stub: stub)
        let preparation = stub.preparationCalls[0]
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        let transactionID = coordinator.snapshot.transaction.id
        let snapshotCount = recorder.snapshots.count
        var lateUpdate = preparation.transaction
        lateUpdate.interpretation = "Too late"
        preparation.onUpdate(lateUpdate)
        XCTAssertFalse(coordinator.apply(edits: Transaction.Edits(nonce: 1)))
        coordinator.startPreparation(forceGasCheck: true)
        XCTAssertFalse(coordinator.retryPreparation())
        coordinator.beginSliderInteraction()
        XCTAssertFalse(coordinator.setFeeForSpeed(value: 50))
        await Task.yield()
        XCTAssertNil(coordinator.snapshot.transaction.interpretation)
        XCTAssertEqual(coordinator.snapshot.phase, .reserved)
        XCTAssertEqual(coordinator.snapshot.transaction.id, transactionID)
        XCTAssertEqual(recorder.snapshots.count, snapshotCount)
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertTrue(coordinator.releaseReservation(reservation))
    }

    func testStartPreparationAfterFinishIsNoOp() async {
        let stub = ApprovalOperationsStub()
        let recorder = ApprovalSnapshotRecorder()
        let coordinator = makeCoordinator(stub: stub, recorder: recorder)
        await prepareToReady(coordinator, stub: stub)
        coordinator.invalidate()
        let snapshotCount = recorder.snapshots.count
        coordinator.startPreparation(forceGasCheck: false)
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertEqual(coordinator.snapshot.phase, .finished)
        XCTAssertEqual(recorder.snapshots.count, snapshotCount)
    }

    #if os(macOS)
    func testNewFeeNoticeIsVisibleAfterScrollingTransactionDetails() async throws {
        var transaction = Self.makeReadyTransaction()
        transaction.interpretation = (1...100).map { "Transaction detail line \($0)" }.joined(separator: "\n")
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(transaction: transaction, stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let lifetime = NativeApprovalReviewLifetime()
        let account = WalletAccount(
            address: transaction.from, coin: .ethereum, derivation: .default,
            derivationPath: "m/44'/60'/0'/0/0", publicKey: "", extendedPublicKey: ""
        )
        let controller = ApproveTransactionViewController.with(
            transaction: transaction, chain: Self.makeNetwork(), account: account,
            walletId: "notice-scroll-test", reviewLifetime: lifetime
        ) { _ in XCTFail("Displaying a notice must not approve") }
        _ = controller.view
        controller.invalidateNativeApprovalReview()
        defer { lifetime.invalidate() }
        coordinator.onSnapshot = { [weak controller] in controller?.render($0) }
        controller.render(coordinator.snapshot)
        let textView = try XCTUnwrap(controller.metaTextView)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        func scrollDown() {
            controller.view.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
            textView.sizeToFit()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 800))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        for index in 0..<2 {
            scrollDown()
            XCTAssertGreaterThan(textView.visibleRect.minY, 500)
            let position = scrollView.contentView.bounds.origin
            controller.render(coordinator.snapshot)
            XCTAssertEqual(scrollView.contentView.bounds.origin, position)

            let task = startPreflight(coordinator)
            await waitFor { stub.preflightCalls.count == index + 1 }
            let call = stub.preflightCalls[index]
            var updated = call.transaction
            updated.replacePreparedFee(.legacy(gasPrice: BigUInt(UInt64(200 + index))), provenance: .init(gasPrice: .automatic))
            call.completion(.walletManagedUpdated(updated, Self.makeEstimate()))
            guard case .reviewRequired = await task.value else { return XCTFail("Expected a fee notice") }
            layout.ensureLayout(for: container)
            let range = (textView.string as NSString).range(of: Strings.feesUpdated)
            XCTAssertNotEqual(range.location, NSNotFound)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let noticeRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            XCTAssertTrue(noticeRect.intersects(textView.visibleRect))
            XCTAssertTrue(controller.okButton.isEnabled)
        }
    }

    func testNativePrimaryActionAndDescriptionFollowInlineRecovery() async throws {
        let cases: [(
            TransactionReviewNotice,
            ApproveTransactionViewController.PrimaryAction,
            (Transaction, GasService.Estimate) -> TransactionFeePreflightResult
        )] = [
            (.feesUpdated, .approve, { transaction, estimate in
                var updated = transaction
                updated.replacePreparedFee(.legacy(gasPrice: 200), provenance: .init(gasPrice: .automatic))
                return .walletManagedUpdated(updated, estimate)
            }),
            (.unsafeFees, .edit, { .userControlledUnsafe($0, $1) }),
            (.feesUnavailable, .retry, { .unavailable($0, $1) }),
        ]
        for (notice, primaryAction, result) in cases {
            let stub = ApprovalOperationsStub()
            let coordinator = makeCoordinator(stub: stub)
            await prepareToReady(coordinator, stub: stub)
            XCTAssertEqual(ApproveTransactionViewController.primaryAction(for: coordinator.snapshot), .approve)
            let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
            XCTAssertEqual(ApproveTransactionViewController.primaryAction(for: coordinator.snapshot), .unavailable)
            let task = Task { await coordinator.preflight(reservation) }
            await waitFor { stub.preflightCalls.count == 1 }
            let call = stub.preflightCalls[0]
            call.completion(result(call.transaction, Self.makeEstimate()))
            guard case .reviewRequired = await task.value else { return XCTFail("Expected inline recovery") }

            XCTAssertEqual(coordinator.snapshot.notice, notice)
            XCTAssertEqual(ApproveTransactionViewController.primaryAction(for: coordinator.snapshot), primaryAction)
            let description = ApproveTransactionViewController.approvalDescription(
                transaction: coordinator.snapshot.transaction,
                chain: Self.makeNetwork(),
                price: nil,
                notice: coordinator.snapshot.notice
            )
            XCTAssertTrue(description.hasPrefix(notice.title))
            if let message = notice.message { XCTAssertTrue(description.contains(message)) }
            XCTAssertTrue(description.contains(Self.makeNetwork().name))
        }
        XCTAssertEqual(ApproveTransactionViewController.PrimaryAction.retry.title, Strings.tryAgain)
        XCTAssertEqual(ApproveTransactionViewController.PrimaryAction.edit.title, Strings.editFees)
    }
    #endif

    private func makeCoordinator(
        transaction: Transaction? = nil,
        network: EthereumNetwork? = nil,
        stub: ApprovalOperationsStub,
        recorder: ApprovalSnapshotRecorder? = nil
    ) -> TransactionApprovalCoordinator {
        TransactionApprovalCoordinator(
            transaction: transaction ?? Self.makeReadyTransaction(),
            network: network ?? Self.makeNetwork(),
            operations: stub.operations,
            onSnapshot: recorder?.record ?? { _ in }
        )
    }

    private func startPreflight(
        _ coordinator: TransactionApprovalCoordinator
    ) -> Task<TransactionPreflightOutcome, Never> {
        let reservation = coordinator.reserveForPreflight()!
        return Task { await coordinator.preflight(reservation) }
    }

    private func onlySnapshot(
        in effects: [TransactionApprovalReducer.Effect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TransactionApprovalSnapshot {
        let snapshots = effects.compactMap { effect -> TransactionApprovalSnapshot? in
            guard case .snapshot(let snapshot) = effect else { return nil }
            return snapshot
        }
        XCTAssertEqual(snapshots.count, 1, file: file, line: line)
        return try XCTUnwrap(snapshots.first, file: file, line: line)
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
private final class ApprovalSnapshotRecorder {
    var snapshots = [TransactionApprovalSnapshot]()

    func record(_ snapshot: TransactionApprovalSnapshot) {
        snapshots.append(snapshot)
    }
}

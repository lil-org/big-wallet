import Foundation
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class TransactionPreparationRaceTests: XCTestCase {
    func testEveryLatePreparationAndEditingOrderingPreservesTheEditedAttempt() async throws {
        let schedules = twoActorInterleavings(first: 3, second: 3)
        XCTAssertEqual(schedules.count, 20)
        for schedule in schedules {
            let probe = PreparationRaceProbe()
            let original = transaction()
            let coordinator = TransactionApprovalCoordinator(transaction: original, network: network(), operations: probe.operations)
            defer { coordinator.invalidate(); probe.finishAll() }
            coordinator.startPreparation(forceGasCheck: false)
            let old = try XCTUnwrap(probe.requests.first)
            old.continuation.yield(.ready(original))
            await expectEventually { coordinator.snapshot.canApprove }
            var editedID: UUID?
            for step in schedule {
                switch (step.actor, step.index) {
                case (.first, 0), (.first, 1):
                    var late = original
                    late.nonce = step.index == 0 ? "0x3" : "0x4"
                    late.replacePreparedFee(
                        .legacy(gasPrice: step.index == 0 ? 11 : 12),
                        provenance: original.feeProvenance
                    )
                    old.continuation.yield(.transactionUpdated(late))
                    if editedID == nil {
                        await expectEventually { coordinator.snapshot.transaction.nonce == late.nonce }
                    }
                case (.first, 2):
                    old.continuation.yield(.feeEstimate(estimate(price: 99)))
                    old.continuation.yield(.ready(original))
                case (.second, 0):
                    XCTAssertTrue(coordinator.apply(edits: .init(gasPrice: 40, nonce: 7)))
                    editedID = coordinator.snapshot.transaction.id
                    await old.terminated.wait()
                case (.second, 1):
                    coordinator.startPreparation(forceGasCheck: true)
                    XCTAssertEqual(probe.requests.count, 2)
                case (.second, 2):
                    let current = try XCTUnwrap(probe.requests.last)
                    current.continuation.yield(.transactionUpdated(current.transaction))
                    current.continuation.yield(.feeEstimate(estimate(price: 40)))
                    current.continuation.yield(.ready(current.transaction))
                    await expectEventually { coordinator.snapshot.canApprove }
                default: XCTFail("Unexpected schedule step")
                }
                if let editedID {
                    XCTAssertEqual(coordinator.snapshot.transaction.id, editedID, "Schedule: \(schedule)")
                    XCTAssertEqual(coordinator.snapshot.transaction.decimalNonceString, "7")
                    XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, .legacy(gasPrice: 40))
                }
            }
            XCTAssertTrue(coordinator.snapshot.canApprove)
            XCTAssertEqual(probe.requests.count, 2)
        }
    }

    func testEveryCancellationAndLateNonceFeeOrReadyOrderingStaysTerminal() async throws {
        let schedules = twoActorInterleavings(first: 3, second: 1)
        XCTAssertEqual(schedules.count, 4)
        for schedule in schedules {
            let probe = PreparationRaceProbe()
            let initial = transaction()
            let coordinator = TransactionApprovalCoordinator(transaction: initial, network: network(), operations: probe.operations)
            defer { coordinator.invalidate(); probe.finishAll() }
            coordinator.startPreparation(forceGasCheck: false)
            let request = try XCTUnwrap(probe.requests.first)
            var cancelled = false
            var frozenNonce: String?
            for step in schedule {
                if step.actor == .second {
                    coordinator.invalidate()
                    cancelled = true
                    frozenNonce = coordinator.snapshot.transaction.nonce
                    await request.terminated.wait()
                } else {
                    switch step.index {
                    case 0:
                        var updated = initial
                        updated.nonce = "0x5"
                        request.continuation.yield(.transactionUpdated(updated))
                        if !cancelled { await expectEventually { coordinator.snapshot.transaction.nonce == "0x5" } }
                    case 1:
                        request.continuation.yield(.feeEstimate(estimate(price: 20)))
                        if !cancelled { await expectEventually { coordinator.snapshot.hasVerifiedFeeEstimate } }
                    case 2:
                        request.continuation.yield(.ready(coordinator.snapshot.transaction))
                        if !cancelled { await expectEventually { coordinator.snapshot.canApprove } }
                    default: XCTFail("Unexpected preparation step")
                    }
                }
                if cancelled {
                    XCTAssertEqual(coordinator.snapshot.phase, .finished)
                    XCTAssertEqual(coordinator.snapshot.transaction.nonce, frozenNonce)
                    XCTAssertFalse(coordinator.snapshot.canApprove)
                    XCTAssertFalse(coordinator.retryPreparation())
                }
            }
            XCTAssertEqual(probe.requests.count, 1)
        }
    }

    func testEveryRetryAndPreparationFailureOrderingUsesOnlyTheCurrentAttempt() async throws {
        let schedules = twoActorInterleavings(first: 3, second: 1)
        XCTAssertEqual(schedules.count, 4)
        for schedule in schedules {
            let probe = PreparationRaceProbe()
            let initial = transaction()
            let coordinator = TransactionApprovalCoordinator(transaction: initial, network: network(), operations: probe.operations)
            defer { coordinator.invalidate(); probe.finishAll() }
            coordinator.startPreparation(forceGasCheck: false)
            let old = try XCTUnwrap(probe.requests.first)
            var failed = false
            var retried = false
            for step in schedule {
                if step.actor == .second {
                    retried = coordinator.retryPreparation()
                    XCTAssertEqual(retried, failed)
                } else {
                    switch step.index {
                    case 0:
                        var updated = initial
                        updated.nonce = "0x3"
                        old.continuation.yield(.transactionUpdated(updated))
                        await expectEventually { coordinator.snapshot.transaction.nonce == "0x3" }
                    case 1:
                        old.continuation.yield(.feeEstimate(estimate(price: 20)))
                        await expectEventually { coordinator.snapshot.hasVerifiedFeeEstimate }
                    case 2:
                        old.continuation.finish(throwing: TransactionPreparationFailure.gasEstimationFailed)
                        await expectEventually { coordinator.snapshot.canRetryPreparation }
                        failed = true
                    default: XCTFail("Unexpected preparation step")
                    }
                }
            }
            if retried {
                let current = try XCTUnwrap(probe.requests.last)
                XCTAssertEqual(probe.requests.count, 2)
                let attempt = coordinator.snapshot.attemptID
                old.continuation.yield(.transactionUpdated(initial))
                old.continuation.yield(.feeEstimate(estimate(price: 99)))
                var replacement = current.transaction
                replacement.nonce = "0x9"
                current.continuation.yield(.transactionUpdated(replacement))
                current.continuation.yield(.feeEstimate(estimate(price: 40)))
                current.continuation.yield(.ready(replacement))
                await expectEventually { coordinator.snapshot.canApprove }
                XCTAssertEqual(coordinator.snapshot.attemptID, attempt)
                XCTAssertEqual(coordinator.snapshot.transaction.nonce, "0x9")
            } else {
                XCTAssertEqual(coordinator.snapshot.phase, .failed)
                XCTAssertEqual(probe.requests.count, 1)
            }
        }
    }

    func testEveryCancellationAndLatePreflightResponseOrdering() async throws {
        let schedules = twoActorInterleavings(first: 1, second: 1)
        XCTAssertEqual(schedules.count, 2)
        for schedule in schedules {
            let probe = PreparationRaceProbe()
            let initial = transaction()
            let coordinator = TransactionApprovalCoordinator(transaction: initial, network: network(), operations: probe.operations)
            defer { coordinator.invalidate(); probe.finishAll() }
            coordinator.startPreparation(forceGasCheck: false)
            try XCTUnwrap(probe.requests.first).continuation.yield(.ready(initial))
            await expectEventually { coordinator.snapshot.canApprove }
            let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
            let pending = Task { await coordinator.preflight(reservation) }
            defer { pending.cancel(); probe.preflightResult.resolve(.safe(initial, estimate(price: 10))) }
            await probe.preflightEntered.wait()
            var cancelled = false
            for step in schedule {
                if step.actor == .second {
                    pending.cancel()
                    cancelled = true
                } else {
                    probe.preflightResult.resolve(.safe(initial, estimate(price: 10)))
                    let result = await pending.value
                    if cancelled {
                        guard case .invalidated = result else { return XCTFail("Late preflight must not approve after cancellation") }
                    } else {
                        guard case .approved(let approved) = result else { return XCTFail("Completed unchanged preflight must approve") }
                        XCTAssertEqual(approved.nonce, initial.nonce)
                        XCTAssertEqual(approved.preparedFee, initial.preparedFee)
                    }
                }
            }
            await expectEventually { coordinator.snapshot.phase == .finished }
            XCTAssertFalse(coordinator.apply(edits: .init(nonce: 9)))
            XCTAssertFalse(coordinator.retryPreparation())
            XCTAssertNil(coordinator.reserveForPreflight())
        }
    }

    private func transaction() -> Transaction {
        Transaction(from: "0x0000000000000000000000000000000000000001", to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0", gas: "0x5208", value: "0x0", data: "0x", feeIntent: .legacy(gasPrice: 10), preparedFee: .legacy(gasPrice: 10), feeSource: .automatic)
    }

    private func network() -> EthereumNetwork {
        EthereumNetwork(chainId: 1, name: "Fixture", symbol: "ETH", rpcEndpoint: .unauthenticated(URL(string: "https://rpc.fixture.invalid")!),
            isTestnet: true, mightShowPrice: false, explorer: nil)
    }

    private func estimate(price: BigUInt) -> GasEstimate {
        GasEstimate(info: .init(recommendedPriorityFee: price, highPriorityFee: price), nextBaseFee: nil,
            support: .legacy, gasPrice: price, endpointChainID: 1)
    }
}

@MainActor
private final class PreparationRaceProbe {
    struct Request {
        let transaction: Transaction
        let continuation: AsyncThrowingStream<TransactionPreparationEvent, Error>.Continuation
        let terminated: TestGate<Void>
    }
    var requests = [Request]()
    let preflightEntered = TestGate<Void>()
    let preflightResult = TestGate<TransactionFeePreflightResult>()

    var operations: TransactionApprovalOperations {
        TransactionApprovalOperations(prepare: { transaction, _, _ in
            let pair = AsyncThrowingStream<TransactionPreparationEvent, Error>.makeStream()
            let terminated = TestGate<Void>()
            pair.continuation.onTermination = { _ in _ = terminated.resolve(()) }
            self.requests.append(Request(transaction: transaction, continuation: pair.continuation, terminated: terminated))
            return pair.stream
        }, preflight: { _, _ in
            self.preflightEntered.resolve(())
            return await self.preflightResult.wait()
        })
    }

    func finishAll() {
        requests.forEach { $0.continuation.finish() }
    }
}

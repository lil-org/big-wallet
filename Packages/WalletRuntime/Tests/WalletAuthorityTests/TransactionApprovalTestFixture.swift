import Foundation
import XCTest
import Synchronization
import WalletDomain
@testable import WalletAuthority
#if SWIFT_PACKAGE
import WalletRuntimeTestSupport
#endif

#if SWIFT_PACKAGE || os(macOS)
@MainActor
extension TransactionApprovalCoordinatorTests {
    func makeCoordinator(
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

    func startPreflight(
        _ coordinator: TransactionApprovalCoordinator
    ) -> Task<TransactionPreflightOutcome, Never> {
        let reservation = coordinator.reserveForPreflight()!
        return Task { await coordinator.preflight(reservation) }
    }

    func prepareToReady(
        _ coordinator: TransactionApprovalCoordinator,
        stub: ApprovalOperationsStub,
        estimate: GasEstimate? = nil
    ) async {
        coordinator.startPreparation(forceGasCheck: false)
        let call = stub.preparationCalls.last!
        call.onUpdate(call.transaction)
        if let estimate { call.onFeeEstimate(estimate) }
        call.completion(.success(call.transaction))
        await waitForSnapshot(coordinator) { ($0.phase) == (.ready) }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
    }

    static func makeReadyTransaction(
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

    static func makeAutomaticIntentTransaction(
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

    static func makeNetwork() -> EthereumNetwork {
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

    static func makeGasInfo() -> GasPriceInfo {
        GasPriceInfo(
            recommendedPriorityFee: 20,
            highPriorityFee: 40
        )
    }

    static func makeEstimate() -> GasEstimate {
        GasEstimate(
            info: Self.makeGasInfo(),
            nextBaseFee: 100,
            currentBaseFee: 90,
            support: .eip1559,
            gasPrice: nil,
            endpointChainID: 10
        )
    }

    static func makeUnknownEstimate(
        currentBaseFee: BigUInt? = nil,
        nextBaseFee: BigUInt? = nil
    ) -> GasEstimate {
        GasEstimate(
            info: nil,
            nextBaseFee: nextBaseFee,
            currentBaseFee: currentBaseFee,
            support: .unknown,
            gasPrice: nil,
            endpointChainID: 10
        )
    }

    static func makeLegacyEstimate() -> GasEstimate {
        GasEstimate(
            info: Self.makeGasInfo(),
            nextBaseFee: nil,
            currentBaseFee: nil,
            support: .legacy,
            gasPrice: 100,
            endpointChainID: 10
        )
    }

    static func makeCatalogHintedNetwork() -> EthereumNetwork {
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


    func waitForCalls(_ stub: ApprovalOperationsStub, _ kind: ApprovalOperationsStub.CallKind, count: Int) async {
        let observed = expectation(description: "transaction operation started")
        let currentCount = { kind == .preparation ? stub.preparationCalls.count : stub.preflightCalls.count }
        var fulfilled = false
        let check = {
            if currentCount() >= count, !fulfilled { fulfilled = true; observed.fulfill() }
        }
        switch kind {
        case .preparation: stub.onPreparationCall = check
        case .preflight: stub.onPreflightCall = check
        }
        defer {
            switch kind {
            case .preparation: stub.onPreparationCall = nil
            case .preflight: stub.onPreflightCall = nil
            }
        }
        check()
        await fulfillment(of: [observed], timeout: 2)
    }

    func waitForCancellation(_ cancellation: TestRequestCancellation) async {
        guard !cancellation.isCancelled else { return }
        await fulfillment(of: [cancellation.recorded], timeout: 2)
    }

    func waitForSnapshot(
        _ coordinator: TransactionApprovalCoordinator,
        _ condition: @escaping (TransactionApprovalSnapshot) -> Bool
    ) async {
        guard !condition(coordinator.snapshot) else { return }
        let observed = expectation(description: "transaction snapshot changed")
        let previous = coordinator.onSnapshot
        var fulfilled = false
        coordinator.onSnapshot = { snapshot in
            previous(snapshot)
            if condition(coordinator.snapshot), !fulfilled { fulfilled = true; observed.fulfill() }
        }
        defer { coordinator.onSnapshot = previous }
        await fulfillment(of: [observed], timeout: 2)
    }
}

@MainActor
final class ApprovalOperationsStub {
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
        func onFeeEstimate(_ estimate: GasEstimate) { continuation.yield(.feeEstimate(estimate)) }
        func completion(_ result: Result<Transaction, TransactionPreparationFailure>) {
            switch result {
            case .success(let value): continuation.yield(.ready(value))
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    final class PreflightCall {
        let transaction: Transaction
        let cancellation = TestDeferred<TransactionFeePreflightResult>()
        init(transaction: Transaction) { self.transaction = transaction }
        func completion(_ result: TransactionFeePreflightResult) { cancellation.resolve(.success(result)) }
    }

    enum CallKind { case preparation, preflight }
    var onPreparationCall: (() -> Void)?
    var onPreflightCall: (() -> Void)?
    var preparationCalls = [PreparationCall]() { didSet { onPreparationCall?() } }
    var preflightCalls = [PreflightCall]() { didSet { onPreflightCall?() } }
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

final class TestRequestCancellation: Sendable {
    let canceled = Mutex(false)
    let recorded = XCTestExpectation(description: "preparation canceled")
    var isCancelled: Bool { canceled.withLock { $0 } }
    func cancel() {
        let changed = canceled.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if changed { recorded.fulfill() }
    }
}


@MainActor
final class ApprovalSnapshotRecorder {
    var snapshots = [TransactionApprovalSnapshot]()

    func record(_ snapshot: TransactionApprovalSnapshot) {
        snapshots.append(snapshot)
    }
}

#endif

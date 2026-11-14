import Foundation
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class TransactionPreflightBoundaryTests: XCTestCase {
    func testPreflightDecisionsPreserveReviewedSigningFields() async throws {
        for result in [TransactionFeePreflightResult.safe(Self.estimate), .userControlledUnsafe(Self.estimate), .unavailable(Self.estimate)] {
            let coordinator = await makeCoordinator { _, _ in result }
            let reviewed = coordinator.snapshot.transaction
            let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
            _ = await coordinator.preflight(reservation)
            assertSameSigningFields(coordinator.snapshot.transaction, reviewed)
        }
    }

    func testEveryPreflightDecisionRejectsAMismatchedEndpoint() async throws {
        let wrongEndpoint = GasEstimate(info: nil, nextBaseFee: nil, support: .legacy, endpointChainID: 2)
        let update = TransactionFeeUpdate(preparedFee: .legacy(gasPrice: 11), provenance: .init(gasPrice: .automatic))
        for result in [TransactionFeePreflightResult.safe(wrongEndpoint), .walletManagedUpdated(update, wrongEndpoint),
                       .userControlledUnsafe(wrongEndpoint), .unavailable(wrongEndpoint)] {
            let coordinator = await makeCoordinator { _, _ in result }
            let reviewed = coordinator.snapshot.transaction
            let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
            guard case .reviewRequired = await coordinator.preflight(reservation) else {
                return XCTFail("A different endpoint chain must require review")
            }
            XCTAssertEqual(coordinator.snapshot.phase, .failed)
            XCTAssertEqual(coordinator.snapshot.notice, .feesUnavailable)
            XCTAssertFalse(coordinator.snapshot.canApprove)
            assertSameSigningFields(coordinator.snapshot.transaction, reviewed)
        }
    }

    func testFeeUpdateOnlyChangesFeesAndRequiresAnotherApproval() async throws {
        let coordinator = await makeCoordinator { transaction, _ in
            .walletManagedUpdated(.init(preparedFee: .legacy(gasPrice: 11), provenance: transaction.feeProvenance), Self.estimate)
        }
        var expected = coordinator.snapshot.transaction
        expected.replacePreparedFee(.legacy(gasPrice: 11), provenance: expected.feeProvenance)
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        guard case .reviewRequired = await coordinator.preflight(reservation) else {
            return XCTFail("Updated fees require a new approval")
        }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertEqual(coordinator.snapshot.notice, .feesUpdated)
        assertSameSigningFields(coordinator.snapshot.transaction, expected)
        XCTAssertNotNil(coordinator.reserveForPreflight())
    }

    func testSafePreflightRefreshesOnlyFeeContext() async throws {
        let coordinator = await makeCoordinator { _, _ in
            .safe(GasEstimate(info: nil, nextBaseFee: 2, currentBaseFee: 1, support: .eip1559, endpointChainID: 1))
        }
        let reviewed = coordinator.snapshot.transaction
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        guard case .approved(let transaction) = await coordinator.preflight(reservation) else {
            return XCTFail("A context refresh must preserve approval")
        }
        assertSameSigningFields(transaction, reviewed)
        XCTAssertEqual(transaction.currentBaseFeePerGas, 1)
        XCTAssertEqual(transaction.nextBaseFeePerGas, 2)
        XCTAssertEqual(transaction.interpretation, reviewed.interpretation)
    }

    private func makeCoordinator(preflight: @escaping TransactionApprovalOperations.Preflight) async -> TransactionApprovalCoordinator {
        let ready = TestGate<Void>()
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.ready)
                    continuation.finish()
                }
            },
            preflight: preflight
        )
        let coordinator = TransactionApprovalCoordinator(
            transaction: Self.transaction,
            network: EthereumNetwork(chainId: 1, name: "Ethereum", symbol: "ETH",
                rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
                isTestnet: false, mightShowPrice: false, explorer: nil),
            operations: operations,
            onSnapshot: { if $0.phase == .ready { ready.resolve(()) } }
        )
        coordinator.startPreparation(forceGasCheck: false)
        await ready.wait()
        return coordinator
    }

    private static var transaction: Transaction {
        Transaction(from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002", nonce: "0x0", gas: "0x5208",
            value: "0x0", data: "0x", feeIntent: .legacy(gasPrice: 10),
            preparedFee: .legacy(gasPrice: 10), feeSource: .automatic)
    }

    private static var estimate: GasEstimate {
        GasEstimate(info: nil, nextBaseFee: nil, support: .legacy, endpointChainID: 1)
    }

    private func assertSameSigningFields(_ actual: Transaction, _ expected: Transaction,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.from, expected.from, file: file, line: line)
        XCTAssertEqual(actual.to, expected.to, file: file, line: line)
        XCTAssertEqual(actual.nonce, expected.nonce, file: file, line: line)
        XCTAssertEqual(actual.gas, expected.gas, file: file, line: line)
        XCTAssertEqual(actual.value, expected.value, file: file, line: line)
        XCTAssertEqual(actual.data, expected.data, file: file, line: line)
        XCTAssertEqual(actual.accessList, expected.accessList, file: file, line: line)
        XCTAssertEqual(actual.preparedFee, expected.preparedFee, file: file, line: line)
        XCTAssertEqual(actual.feeProvenance, expected.feeProvenance, file: file, line: line)
    }
}

import Foundation
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class TransactionPreflightBoundaryTests: XCTestCase {
    private enum Mutation: CaseIterable, Sendable {
        case from, to, nonce, gas, value, data, accessList, chain, fee, provenance
    }

    func testSafePreflightCannotReplaceAnyReviewedSigningField() async throws {
        for mutation in Mutation.allCases {
            let coordinator = await makeCoordinator { transaction, _ in
                var candidate = Self.mutating(transaction, mutation: mutation)
                var estimate = Self.estimate
                if mutation == .chain {
                    estimate = GasEstimate(info: nil, nextBaseFee: nil, support: .legacy, endpointChainID: 2)
                }
                if mutation == .fee {
                    candidate.replacePreparedFee(.legacy(gasPrice: 11), provenance: transaction.feeProvenance)
                }
                if mutation == .provenance {
                    candidate.replaceFeeProvenance(.init(gasPrice: .manual))
                }
                return .safe(candidate, estimate)
            }
            let reviewed = coordinator.snapshot.transaction
            let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
            guard case .reviewRequired = await coordinator.preflight(reservation) else {
                return XCTFail("Altered \(mutation) must require a new review")
            }
            XCTAssertEqual(coordinator.snapshot.phase, .failed, "\(mutation)")
            XCTAssertEqual(coordinator.snapshot.notice, .feesUnavailable, "\(mutation)")
            XCTAssertFalse(coordinator.snapshot.canApprove, "\(mutation)")
            assertSameSigningFields(coordinator.snapshot.transaction, reviewed)
        }
    }

    func testFeeUpdateMayOnlyChangeFeesAndRequiresAnotherApproval() async throws {
        let coordinator = await makeCoordinator { transaction, _ in
            var candidate = transaction
            candidate.replacePreparedFee(.legacy(gasPrice: 11), provenance: transaction.feeProvenance)
            return .walletManagedUpdated(candidate, Self.estimate)
        }
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        guard case .reviewRequired = await coordinator.preflight(reservation) else {
            return XCTFail("Updated fees require a new approval")
        }
        XCTAssertEqual(coordinator.snapshot.phase, .ready)
        XCTAssertEqual(coordinator.snapshot.notice, .feesUpdated)
        XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, .legacy(gasPrice: 11))

        for mutation in [Mutation.nonce, .gas, .from, .to, .value, .data, .accessList, .chain] {
            let altered = await makeCoordinator { transaction, _ in
                let estimate = mutation == .chain
                    ? GasEstimate(info: nil, nextBaseFee: nil, support: .legacy, endpointChainID: 2)
                    : Self.estimate
                return .walletManagedUpdated(Self.mutating(transaction, mutation: mutation), estimate)
            }
            let reviewed = altered.snapshot.transaction
            let claim = try XCTUnwrap(altered.reserveForPreflight())
            guard case .reviewRequired = await altered.preflight(claim) else {
                return XCTFail("Unexpected \(mutation) change must fail the preflight")
            }
            XCTAssertEqual(altered.snapshot.phase, .failed)
            assertSameSigningFields(altered.snapshot.transaction, reviewed)
        }
    }

    func testSafePreflightMayRefreshBaseFeeAndDisplayContext() async throws {
        let coordinator = await makeCoordinator { transaction, _ in
            var candidate = transaction
            candidate.interpretation = "Updated interpretation"
            candidate.currentBaseFeePerGas = 1
            candidate.nextBaseFeePerGas = 2
            return .safe(candidate, GasEstimate(info: nil, nextBaseFee: 2, currentBaseFee: 1,
                support: .eip1559, endpointChainID: 1))
        }
        let reviewed = coordinator.snapshot.transaction
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        guard case .approved(let transaction) = await coordinator.preflight(reservation) else {
            return XCTFail("A context refresh must preserve approval")
        }
        assertSameSigningFields(transaction, reviewed)
        XCTAssertEqual(transaction.currentBaseFeePerGas, 1)
        XCTAssertEqual(transaction.nextBaseFeePerGas, 2)
        XCTAssertEqual(transaction.interpretation, "Updated interpretation")
    }

    private func makeCoordinator(preflight: @escaping TransactionApprovalOperations.Preflight) async -> TransactionApprovalCoordinator {
        let ready = TestGate<Void>()
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.transactionUpdated(transaction))
                    continuation.yield(.ready(transaction))
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

    private static func mutating(_ transaction: Transaction, mutation: Mutation) -> Transaction {
        var result = Transaction(id: transaction.id,
            from: mutation == .from ? "0x0000000000000000000000000000000000000003" : transaction.from,
            to: mutation == .to ? "0x0000000000000000000000000000000000000003" : transaction.to,
            nonce: mutation == .nonce ? "0x1" : transaction.nonce,
            gas: mutation == .gas ? "0xffff" : transaction.gas,
            value: mutation == .value ? "0x1" : transaction.value,
            data: mutation == .data ? "0x01" : transaction.data,
            feeIntent: transaction.feeIntent, preparedFee: transaction.preparedFee,
            feeProvenance: transaction.feeProvenance, accessList: transaction.accessList)
        if mutation == .accessList {
            result.accessList = [EthereumAccessListEntry(address: transaction.to, storageKeys: [])!]
        }
        return result
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

import Foundation
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class TransactionPreparationBoundaryTests: XCTestCase {
    private enum Mutation: CaseIterable {
        case from, to, value, data, accessList, feeIntent
    }

    func testPreparationUpdatesCannotReplaceTheDisplayedImmutablePayload() async throws {
        for mutation in Mutation.allCases {
            let fixture = makeCoordinator()
            defer { fixture.coordinator.invalidate(); fixture.continuation.finish() }
            let original = fixture.coordinator.snapshot.transaction
            fixture.coordinator.startPreparation(forceGasCheck: false)
            fixture.continuation.yield(.transactionUpdated(mutating(original, mutation: mutation)))
            fixture.continuation.yield(.ready(original))
            await expectEventually { fixture.coordinator.snapshot.phase == .failed }
            assertImmutableFields(fixture.coordinator.snapshot.transaction, original)
            XCTAssertEqual(fixture.coordinator.snapshot.notice, .preparationFailed(.invalidTransaction), "\(mutation)")
            XCTAssertFalse(fixture.coordinator.snapshot.canApprove)
            XCTAssertNil(fixture.coordinator.reserveForPreflight())
            XCTAssertEqual(fixture.preflightCalls.count, 0)
        }
    }

    func testTerminalReadyCannotBypassImmutablePreparationValidation() async throws {
        for mutation in Mutation.allCases {
            let fixture = makeCoordinator()
            defer { fixture.coordinator.invalidate(); fixture.continuation.finish() }
            let original = fixture.coordinator.snapshot.transaction
            fixture.coordinator.startPreparation(forceGasCheck: false)
            fixture.continuation.yield(.transactionUpdated(original))
            fixture.continuation.yield(.ready(mutating(original, mutation: mutation)))
            await expectEventually { fixture.coordinator.snapshot.phase == .failed }
            assertImmutableFields(fixture.coordinator.snapshot.transaction, original)
            XCTAssertFalse(fixture.coordinator.snapshot.canApprove)
            XCTAssertNil(fixture.coordinator.reserveForPreflight())
            XCTAssertEqual(fixture.preflightCalls.count, 0)
        }
    }

    func testLateInterpretationUpdateCannotReplaceAnAlreadyReviewablePayload() async throws {
        let fixture = makeCoordinator()
        defer { fixture.coordinator.invalidate(); fixture.continuation.finish() }
        let original = fixture.coordinator.snapshot.transaction
        fixture.coordinator.startPreparation(forceGasCheck: false)
        fixture.continuation.yield(.ready(original))
        await expectEventually { fixture.coordinator.snapshot.canApprove }
        var changed = mutating(original, mutation: .data)
        changed.interpretation = "Late decoded interpretation"
        fixture.continuation.yield(.transactionUpdated(changed))
        await expectEventually { fixture.coordinator.snapshot.phase == .failed }
        assertImmutableFields(fixture.coordinator.snapshot.transaction, original)
        XCTAssertNil(fixture.coordinator.snapshot.transaction.interpretation)
        XCTAssertNil(fixture.coordinator.reserveForPreflight())
        XCTAssertEqual(fixture.preflightCalls.count, 0)
    }

    func testPreparationMayUpdateNonceGasFeesAndInterpretationBeforeApproval() async throws {
        let fixture = makeCoordinator()
        defer { fixture.coordinator.invalidate(); fixture.continuation.finish() }
        let original = fixture.coordinator.snapshot.transaction
        var updated = original
        updated.nonce = "0x7"
        updated.gas = "0x6000"
        updated.replacePreparedFee(.legacy(gasPrice: 20), provenance: .init(gasPrice: .automatic))
        updated.interpretation = "Decoded immutable call"
        fixture.coordinator.startPreparation(forceGasCheck: false)
        fixture.continuation.yield(.transactionUpdated(updated))
        fixture.continuation.yield(.feeEstimate(Self.estimate))
        fixture.continuation.yield(.ready(updated))
        await expectEventually { fixture.coordinator.snapshot.canApprove }
        assertImmutableFields(fixture.coordinator.snapshot.transaction, original)
        XCTAssertEqual(fixture.coordinator.snapshot.transaction.nonce, "0x7")
        XCTAssertEqual(fixture.coordinator.snapshot.transaction.gas, "0x6000")
        XCTAssertEqual(fixture.coordinator.snapshot.transaction.preparedFee, .legacy(gasPrice: 20))
        XCTAssertEqual(fixture.coordinator.snapshot.transaction.interpretation, updated.interpretation)

        let reservation = try XCTUnwrap(fixture.coordinator.reserveForPreflight())
        guard case .approved(let approved) = await fixture.coordinator.preflight(reservation) else {
            return XCTFail("Allowed preparation fields must remain approvable")
        }
        assertImmutableFields(approved, original)
        XCTAssertEqual(approved.nonce, updated.nonce)
        XCTAssertEqual(approved.gas, updated.gas)
        XCTAssertEqual(approved.preparedFee, updated.preparedFee)
        XCTAssertEqual(fixture.preflightCalls.count, 1)
    }

    func testEditedTransactionCanReprepareAndApproveWithItsNewIdentity() async throws {
        let original = Self.transaction
        let coordinator = TransactionApprovalCoordinator(transaction: original, network: Self.network, operations: .init(
            prepare: { transaction, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.transactionUpdated(transaction))
                    continuation.yield(.feeEstimate(Self.estimate))
                    continuation.yield(.ready(transaction))
                    continuation.finish()
                }
            },
            preflight: { transaction, _ in .safe(transaction, Self.estimate) }
        ))
        defer { coordinator.invalidate() }
        coordinator.startPreparation(forceGasCheck: false)
        await expectEventually { coordinator.snapshot.canApprove }
        XCTAssertTrue(coordinator.apply(edits: .init(gasPrice: 25, nonce: 8)))
        let edited = coordinator.snapshot.transaction
        XCTAssertNotEqual(edited.id, original.id)
        coordinator.startPreparation(forceGasCheck: true)
        await expectEventually { coordinator.snapshot.canApprove }
        XCTAssertEqual(coordinator.snapshot.transaction.id, edited.id)
        XCTAssertEqual(coordinator.snapshot.transaction.decimalNonceString, "8")
        XCTAssertEqual(coordinator.snapshot.transaction.preparedFee, .legacy(gasPrice: 25))
        let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
        guard case .approved(let approved) = await coordinator.preflight(reservation) else {
            return XCTFail("An explicitly edited review must remain approvable after preparation")
        }
        assertImmutableFields(approved, edited)
        XCTAssertEqual(approved.nonce, edited.nonce)
        XCTAssertEqual(approved.preparedFee, edited.preparedFee)
    }

    func testNativeReviewRejectsAlteredImmutablePayloadWithoutPreparationCoordinator() throws {
        let fixture = try ApprovedExecutionTestFixture()
        let account = WalletAccountDescriptor(walletID: "review-wallet", coin: .ethereum,
            normalizedAddress: Self.transaction.from, derivationPath: "m/44'/60'/0'/0/0")
        try fixture.establishGrant(account, profileIdentifier: nil)
        let snapshot = try fixture.enqueue(id: 12, name: "signTransaction", provider: .ethereum, body: [
            "address": account.normalizedAddress, "chainId": "0x1", "object": [
                "to": Self.transaction.to, "value": "0x0", "data": "0x", "nonce": "0x0", "gas": "0x5208", "gasPrice": "0xa",
            ],
        ])
        let network = ResolvedEthereumNetwork(network: Self.network, source: .custom)
        let action = DappRequestAction.approveTransaction(.init(transaction: Self.transaction, resolvedNetwork: network,
            walletId: account.walletID, account: account.account))
        let review = NativeApprovalReview(intent: try reviewIntentForTesting(binding: XCTUnwrap(snapshot.requestBinding), action: action))
        defer { review.invalidate() }
        guard case .approveTransaction(let prepared) = review.action else { return XCTFail("Expected transaction review") }
        var ready = prepared.transaction
        ready.nonce = "0x0"
        ready.gas = "0x5208"
        ready.replacePreparedFee(.legacy(gasPrice: 10), provenance: ready.feeProvenance)
        XCTAssertNotNil(review.makeTransactionAuthenticationChallenge(transaction: ready, reviewedNetwork: network))
        for mutation in Mutation.allCases {
            XCTAssertNil(review.makeTransactionAuthenticationChallenge(transaction: mutating(ready, mutation: mutation), reviewedNetwork: network), "\(mutation)")
        }
        var edited = ready
        XCTAssertTrue(edited.apply(.init(gasPrice: 20, nonce: 7)))
        edited.gas = "0x6000"
        XCTAssertNotEqual(edited.id, ready.id)
        XCTAssertNotNil(review.makeTransactionAuthenticationChallenge(transaction: edited, reviewedNetwork: network))
    }

    @MainActor
    private final class PreflightCalls {
        var count = 0
    }

    private struct Fixture {
        let coordinator: TransactionApprovalCoordinator
        let continuation: AsyncThrowingStream<TransactionPreparationEvent, Error>.Continuation
        let preflightCalls: PreflightCalls
    }

    private func makeCoordinator() -> Fixture {
        let pair = AsyncThrowingStream<TransactionPreparationEvent, Error>.makeStream()
        let calls = PreflightCalls()
        let coordinator = TransactionApprovalCoordinator(transaction: Self.transaction, network: Self.network,
            operations: .init(prepare: { _, _, _ in pair.stream }, preflight: { transaction, _ in
                calls.count += 1
                return .safe(transaction, Self.estimate)
            }))
        return Fixture(coordinator: coordinator, continuation: pair.continuation, preflightCalls: calls)
    }

    private static var transaction: Transaction {
        Transaction(from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002", nonce: "0x0", gas: "0x5208", value: "0x0", data: "0x",
            feeIntent: .legacy(gasPrice: 10), preparedFee: .legacy(gasPrice: 10), feeSource: .automatic)
    }

    private static var network: EthereumNetwork {
        EthereumNetwork(chainId: 1, name: "Fixture", symbol: "ETH", rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
            isTestnet: false, mightShowPrice: false, explorer: nil)
    }

    private static var estimate: GasEstimate {
        GasEstimate(info: nil, nextBaseFee: nil, support: .legacy, gasPrice: 20, endpointChainID: 1)
    }

    private func mutating(_ transaction: Transaction, mutation: Mutation) -> Transaction {
        var result = Transaction(id: transaction.id,
            from: mutation == .from ? "0x0000000000000000000000000000000000000003" : transaction.from,
            to: mutation == .to ? "0x0000000000000000000000000000000000000003" : transaction.to,
            nonce: transaction.nonce, gas: transaction.gas,
            value: mutation == .value ? "0x1" : transaction.value,
            data: mutation == .data ? "0x0102" : transaction.data,
            feeIntent: mutation == .feeIntent ? .automatic : transaction.feeIntent,
            preparedFee: transaction.preparedFee, feeProvenance: transaction.feeProvenance, accessList: transaction.accessList)
        if mutation == .accessList { result.accessList = [EthereumAccessListEntry(address: transaction.to, storageKeys: [])!] }
        return result
    }

    private func assertImmutableFields(_ actual: Transaction, _ expected: Transaction,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.from, expected.from, file: file, line: line)
        XCTAssertEqual(actual.to, expected.to, file: file, line: line)
        XCTAssertEqual(actual.value, expected.value, file: file, line: line)
        XCTAssertEqual(actual.data, expected.data, file: file, line: line)
        XCTAssertEqual(actual.accessList, expected.accessList, file: file, line: line)
        XCTAssertEqual(actual.feeIntent, expected.feeIntent, file: file, line: line)
    }
}

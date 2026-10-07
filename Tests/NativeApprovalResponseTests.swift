#if os(macOS)
import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeApprovalResponseTests: XCTestCase {
    func testReactivationReportsDecisionThatArrivesWhilePresentationIsBeingRestored() async throws {
        for completed in [false, true] {
            let fixture = try NativeApprovalServiceTestFixture()
            let request = try fixture.request(manual: true)
            fixture.deliver(request)
            fixture.onLoad = { handle in
                if fixture.loads.count == 3 {
                    if completed {
                        fixture.setState(.responded, for: request)
                    } else {
                        fixture.deliver(request, executing: true)
                    }
                }
                return fixture.snapshots[handle].map(ExtensionBridge.SnapshotResult.found) ?? .missing
            }
            defer { fixture.onLoad = nil }
            let service = fixture.service()
            let result = try await fixture.finish {
                await service.reconcile(.init(request), intent: .focus)
            }
            XCTAssertEqual(result, completed ? .responseReady : .pending)
            XCTAssertTrue(fixture.launches.isEmpty)
            XCTAssertTrue(fixture.clears.isEmpty)
            XCTAssertTrue(fixture.quits.isEmpty)
        }
    }

    func testReactivationDoesNotReportQueuedOrUnreadableApprovalAsHandled() async throws {
        let fixture = try NativeApprovalServiceTestFixture()
        let request = try fixture.request(manual: true)
        let service = fixture.service()
        fixture.deliver(request)
        let delivered = try XCTUnwrap(fixture.snapshots[request.handle])
        fixture.onValidate = { _ in false }
        for loaded in [ExtensionBridge.SnapshotResult.found(request), .found(delivered), .missing, .unavailable] {
            fixture.onLoad = { _ in loaded }
            let result = await service.reconcile(.init(request), intent: .focus)
            switch loaded {
            case .missing: XCTAssertEqual(result, .missing)
            case .found, .unavailable: XCTAssertEqual(result, .unavailable)
            }
        }
        fixture.onValidate = nil
        fixture.onLoad = nil
        XCTAssertTrue(fixture.launches.isEmpty)
    }

    func testReactivationCompletionMustMatchTheExactStoredIdentity() async throws {
        let fixture = try NativeApprovalServiceTestFixture()
        let request = try fixture.request(manual: true)
        let otherRequest = try fixture.request(id: 2, manual: true)
        fixture.setState(.responded, for: request)
        let completed = try XCTUnwrap(fixture.snapshots[request.handle])
        fixture.onLoad = { _ in .found(completed) }
        let service = fixture.service()
        for (handle, key, nonce) in [
            (otherRequest.handle, request.configurationKey, request.nativeDeliveryNonce),
            (request.handle, "https://another.example", request.nativeDeliveryNonce),
            (request.handle, request.configurationKey, otherRequest.nativeDeliveryNonce),
        ] {
            let result = await service.reconcile(
                .init(handle: handle, configurationKey: key, expectedNonce: nonce),
                intent: .focus
            )
            XCTAssertEqual(result, .missing)
        }
        fixture.onLoad = nil
        XCTAssertTrue(fixture.launches.isEmpty)
    }

    func testNativeExecutionCannotBeTriggeredByWorkerMessage() throws {
        let message: [String: Any] = [
            "subject": "executeNativeApproval", "id": 42,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "configurationKey": "https://wallet.example",
            "requestToken": UUID().uuidString.lowercased(),
            "claimID": UUID().uuidString.lowercased(),
            "revisions": ["ethereum": 2, "solana": 3],
            "executionDeadline": 1_800_000_100_000,
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            InternalSafariRequest.self,
            from: JSONSerialization.data(withJSONObject: message)
        ))
    }

    func testRevokedAuthorityNeverCallsSigner() async throws {
        let underlying = AuthorityTestAccess()
        let context = try signingContext(access: underlying)
        revokeAuthority(in: context.fixture)
        let result = await context.signer.sign()
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Revoked authority must not sign")
        }
        XCTAssertEqual(underlying.calls, 0)
        XCTAssertTrue(underlying.invalidated)
    }

    func testRevocationDuringSigningDiscardsSignature() async throws {
        let underlying = AuthorityTestAccess()
        let context = try signingContext(access: underlying)
        underlying.operation = { self.revokeAuthority(in: context.fixture) }
        let result = await context.signer.sign()
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("A signature produced after revocation must not escape")
        }
        XCTAssertEqual(underlying.calls, 1)
        XCTAssertTrue(underlying.invalidated)
    }

    func testCurrentAuthorityReturnsSignatureOnce() async throws {
        let underlying = AuthorityTestAccess()
        let context = try signingContext(access: underlying)
        let result = await context.signer.sign()
        guard case .success = result else {
            return XCTFail("Expected authorized signature")
        }
        guard case .failure(.authorizationUnavailable) = await context.signer.sign() else {
            return XCTFail("An authorized signature must be returned only once")
        }
        XCTAssertEqual(underlying.calls, 1)
        XCTAssertTrue(underlying.invalidated)
    }

    private func revokeAuthority(in fixture: ApprovedExecutionTestFixture) {
        guard case .snapshot(let authority) = fixture.store.configurationSnapshot(
            configurationKey: "https://wallet.example", profileIdentifier: nil
        ), case .revoked = fixture.store.revoke(
            configurationKey: "https://wallet.example", provider: .ethereum,
            attempt: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            expected: authority.version, profileIdentifier: nil
        ) else {
            return XCTFail("Expected durable authority revocation")
        }
    }

    private func signingContext(
        access: AuthorityTestAccess
    ) throws -> (signer: WalletSigningSession, fixture: ApprovedExecutionTestFixture) {
        let account = WalletAccountDescriptor(
            walletID: "approved-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        )
        let fixture = try ApprovedExecutionTestFixture()
        try fixture.establishGrant(account)
        let snapshot = try fixture.enqueue(
            id: 1, name: "signPersonalMessage", provider: .ethereum,
            body: ["address": account.normalizedAddress, "chainId": "0x1", "object": ["data": "0x01"]]
        )
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: Data()), orderedAccounts: [account.specificAccount]
        )
        guard case .approval(let intent) = DappRequestProcessor().prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { throw CocoaError(.coderInvalidValue) }
        let permit = try fixture.authorize(
            snapshot: snapshot, action: intent.action,
            decision: .message(.init(approvedAccount: account, solanaCluster: nil))
        )
        XCTAssertTrue(permit.consumeExecution())
        let authorization = try XCTUnwrap(WalletSigningAuthorization(permit: permit))
        let session = WalletSigningSession(access, authorization: authorization, isCurrent: { true })
        XCTAssertTrue(session.attach(permit: permit))
        return (session, fixture)
    }

}

@MainActor
private final class AuthorityTestAccess: OwnedWalletSigningAccess {
    var calls = 0
    private nonisolated let invalidation = Mutex(false)
    nonisolated var invalidated: Bool { invalidation.withLock { $0 } }
    var operation: @MainActor () -> Void = {}

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        calls += 1
        let result = walletSigningResultForTesting(operation)
        self.operation()
        return result
    }

    nonisolated func invalidate() {
        invalidation.withLock { $0 = true }
    }
}
#endif

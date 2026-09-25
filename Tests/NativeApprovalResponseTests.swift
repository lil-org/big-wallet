#if os(macOS)
import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeApprovalResponseTests: XCTestCase {
    func testReactivationReportsDecisionThatArrivesWhilePresentationIsBeingRestored() async throws {
        for completed in [false, true] {
            let fixture = try NativeApprovalServiceTestFixture()
            let request = try fixture.request(manual: true)
            fixture.deliver(request)
            fixture.onValidate = { _ in
                if completed {
                    fixture.setState(.responded, for: request)
                } else {
                    fixture.deliver(request, executing: true)
                }
                return true
            }
            defer { fixture.onValidate = nil }
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
            "attemptID": UUID().uuidString.lowercased(),
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
        let signer = try signer(access: underlying, authorityIsCurrent: { _ in false })
        let result = await signer.sign()
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Revoked authority must not sign")
        }
        XCTAssertEqual(underlying.calls, 0)
        XCTAssertTrue(underlying.invalidated)
    }

    func testRevocationDuringSigningDiscardsSignature() async throws {
        let underlying = AuthorityTestAccess()
        var isCurrent = true
        underlying.operation = { isCurrent = false }
        let signer = try signer(access: underlying, authorityIsCurrent: { _ in isCurrent })
        let result = await signer.sign()
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("A signature produced after revocation must not escape")
        }
        XCTAssertEqual(underlying.calls, 1)
        XCTAssertTrue(underlying.invalidated)
    }

    func testCurrentAuthorityReturnsSignatureAfterCheckingTheStoredHandleTwice() async throws {
        let underlying = AuthorityTestAccess()
        var handles = [ExtensionBridge.Handle]()
        let signer = try signer(access: underlying, authorityIsCurrent: { handle in
            handles.append(handle)
            return true
        })
        let result = await signer.sign()
        guard case .success(.ethereumSignature("signed")) = result else {
            return XCTFail("Expected authorized signature")
        }
        XCTAssertEqual(handles, [signer.authorization.handle, signer.authorization.handle])
        XCTAssertEqual(underlying.calls, 1)
        XCTAssertTrue(underlying.invalidated)
    }

    private func signer(
        access: AuthorityTestAccess,
        authorityIsCurrent: @escaping @MainActor (ExtensionBridge.Handle) async -> Bool
    ) throws -> WalletSigningSession {
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: .init(
            walletID: "approved-wallet",
            coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        let session = WalletSigningSession(access, authorization: operation.authorization, isCurrent: { true })
        XCTAssertTrue(session.bind(operation: operation, authorityIsCurrent: authorityIsCurrent))
        return session
    }
}

private final class AuthorityTestAccess: OwnedWalletSigningAccess {
    var calls = 0
    var invalidated = false
    var operation: @MainActor () -> Void = {}

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        calls += 1
        self.operation()
        return .success(.ethereumSignature("signed"))
    }

    func invalidate() {
        invalidated = true
    }
}
#endif

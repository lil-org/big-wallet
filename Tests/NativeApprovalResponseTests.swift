#if os(macOS)
import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeApprovalResponseTests: XCTestCase {
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

    func testRevokedAuthorityNeverCallsSigner() async {
        let underlying = AuthorityTestSigner()
        let signer = AuthorityBoundWalletSigner(signer: underlying, authorityIsCurrent: { false })
        let result = await signer.sign()
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Revoked authority must not sign")
        }
        XCTAssertEqual(underlying.calls, 0)
        XCTAssertTrue(underlying.invalidated)
    }

    func testRevocationDuringSigningDiscardsSignature() async {
        let underlying = AuthorityTestSigner()
        var isCurrent = true
        underlying.operation = { isCurrent = false }
        let signer = AuthorityBoundWalletSigner(signer: underlying, authorityIsCurrent: { isCurrent })
        let result = await signer.sign()
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("A signature produced after revocation must not escape")
        }
        XCTAssertEqual(underlying.calls, 1)
        XCTAssertTrue(underlying.invalidated)
    }

    func testCurrentAuthorityReturnsSignatureAfterBothChecks() async {
        let underlying = AuthorityTestSigner()
        var checks = 0
        let signer = AuthorityBoundWalletSigner(signer: underlying, authorityIsCurrent: {
            checks += 1
            return true
        })
        let result = await signer.sign()
        guard case .success(.ethereumSignature("signed")) = result else {
            return XCTFail("Expected authorized signature")
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(underlying.calls, 1)
    }
}

private final class AuthorityTestSigner: WalletSigning {
    var calls = 0
    var invalidated = false
    var operation: @MainActor () -> Void = {}

    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        calls += 1
        operation()
        return .success(.ethereumSignature("signed"))
    }

    func invalidate() {
        invalidated = true
    }
}
#endif

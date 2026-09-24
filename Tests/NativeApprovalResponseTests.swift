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

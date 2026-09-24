import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class WalletSigningSessionTests: XCTestCase {
    func testBindingRejectsAnotherAuthorizationAndCannotBeReplaced() async throws {
        let operation = try operation()
        let material = SessionSigningMaterial { .success(.ethereumSignature("signed")) }
        let session = WalletSigningSession(
            material, authorization: operation.authorization, isCurrent: { true }
        )
        let different = try self.operation(requestID: 2)
        XCTAssertFalse(session.bind(operation: different, authorityIsCurrent: { _ in true }))
        XCTAssertTrue(session.bind(operation: operation, authorityIsCurrent: { _ in true }))
        XCTAssertFalse(session.bind(operation: operation, authorityIsCurrent: { _ in true }))

        guard case .success(.ethereumSignature("signed")) = await session.sign() else {
            return XCTFail("The original authorized operation must sign")
        }
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A session must sign at most once")
        }
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
    }

    func testFailedSigningErasesMaterialAndStillAllowsOneCommitLease() async throws {
        let operation = try operation()
        let material = SessionSigningMaterial { .failure(.failedToSign) }
        let released = expectation(description: "Transferred lease released")
        var acquisitions = 0
        let session = WalletSigningSession(
            material,
            authorization: operation.authorization,
            isCurrent: { true },
            acquireCommitLease: {
                acquisitions += 1
                return WalletExecutionLease { released.fulfill() }
            }
        )
        XCTAssertTrue(session.bind(operation: operation, authorityIsCurrent: { _ in true }))
        guard case .failure(.failedToSign) = await session.sign() else {
            return XCTFail("The signing failure must be preserved")
        }
        XCTAssertEqual(material.erasureCount, 1)
        XCTAssertTrue(session.validateCurrent())

        let acquired = await session.takeCommitLease()
        let lease = try XCTUnwrap(acquired)
        let duplicate = await session.takeCommitLease()
        XCTAssertNil(duplicate)
        XCTAssertEqual(acquisitions, 1)
        session.invalidate()
        XCTAssertEqual(material.erasureCount, 1)
        lease.release()
        await fulfillment(of: [released], timeout: 1)
    }

    func testInvalidationDisposesOfLeaseArrivingAfterAcquisitionStarted() async throws {
        let operation = try operation()
        let material = SessionSigningMaterial { .success(.ethereumSignature("signed")) }
        let acquisitionStarted = expectation(description: "Acquisition started")
        let released = expectation(description: "Late lease released")
        let resolution = ApprovalResolution<WalletExecutionLease?>()
        let session = WalletSigningSession(
            material,
            authorization: operation.authorization,
            isCurrent: { true },
            acquireCommitLease: {
                acquisitionStarted.fulfill()
                return await resolution.value()
            }
        )
        XCTAssertTrue(session.bind(operation: operation, authorityIsCurrent: { _ in true }))
        let acquisition = Task { await session.takeCommitLease() }
        await fulfillment(of: [acquisitionStarted], timeout: 1)
        XCTAssertEqual(material.erasureCount, 1)
        session.invalidate()
        await resolution.resolve(WalletExecutionLease { released.fulfill() })

        let lease = await acquisition.value
        XCTAssertNil(lease)
        await fulfillment(of: [released], timeout: 1)
        XCTAssertFalse(session.validateCurrent())
        XCTAssertEqual(material.erasureCount, 1)
    }

    func testCommitAcquisitionFencesSignatureAlreadyBeingProduced() async throws {
        let operation = try operation()
        let signingStarted = expectation(description: "Signing started")
        let resolution = ApprovalResolution<Result<WalletSigningOutput, WalletSigningFailure>>()
        let material = SessionSigningMaterial {
            signingStarted.fulfill()
            return await resolution.value()
        }
        let session = WalletSigningSession(
            material,
            authorization: operation.authorization,
            isCurrent: { true },
            acquireCommitLease: { WalletExecutionLease(release: {}) }
        )
        XCTAssertTrue(session.bind(operation: operation, authorityIsCurrent: { _ in true }))
        let signing = Task { await session.sign() }
        await fulfillment(of: [signingStarted], timeout: 1)
        let acquired = await session.takeCommitLease()
        let lease = try XCTUnwrap(acquired)
        XCTAssertEqual(material.erasureCount, 1)
        await resolution.resolve(.success(.ethereumSignature("too late")))

        guard case .failure(.authorizationUnavailable) = await signing.value else {
            lease.release()
            return XCTFail("An in-flight signature must not escape after commit acquisition")
        }
        lease.release()
        session.invalidate()
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
    }

    private func operation(requestID: Int = 1) throws -> ApprovedWalletSigningOperation {
        try approvedWalletSigningOperationForTesting(
            approvedAccount: WalletAccountDescriptor(
                walletID: "session-wallet",
                coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ),
            requestID: requestID
        )
    }
}

private final class SessionSigningMaterial: OwnedWalletSigningAccess {
    private let lock = NSLock()
    private var signs = 0
    private var erasures = 0
    private let operation: @MainActor () async -> Result<WalletSigningOutput, WalletSigningFailure>

    var signCount: Int { lock.withLock { signs } }
    var erasureCount: Int { lock.withLock { erasures } }

    init(operation: @escaping @MainActor () async -> Result<WalletSigningOutput, WalletSigningFailure>) {
        self.operation = operation
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        lock.withLock { signs += 1 }
        return await self.operation()
    }

    func invalidate() {
        lock.withLock { erasures += 1 }
    }
}

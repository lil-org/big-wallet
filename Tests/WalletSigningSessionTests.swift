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

@MainActor
final class UnlockedAccountSignerTests: XCTestCase {
    func testInitializationRejectsInvalidDescriptorsAndMismatchedKeys() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let otherKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 7, count: 32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let invalid = [
                WalletAccountDescriptor(walletID: "", account: approved.account),
                WalletAccountDescriptor(
                    walletID: approved.walletID, coin: coin,
                    normalizedAddress: "invalid", derivationPath: approved.derivationPath
                ),
                WalletAccountDescriptor(
                    walletID: approved.walletID, coin: coin,
                    normalizedAddress: approved.normalizedAddress, derivationPath: ""
                ),
            ]
            for account in invalid {
                XCTAssertNil(UnlockedAccountSigner(approvedAccount: account, privateKey: key))
            }
            XCTAssertNil(UnlockedAccountSigner(approvedAccount: approved, privateKey: otherKey))
        }

        let invalidEthereumKey = try XCTUnwrap(WalletPrivateKey(
            data: WalletCoreProxyTestVectors.secp256k1PrivateKeyAtCurveOrder
        ))
        XCTAssertNil(UnlockedAccountSigner(
            approvedAccount: descriptor(coin: .ethereum, key: key), privateKey: invalidEthereumKey
        ))
    }

    func testSignerRejectsOtherAccountIdentitiesAndSignsApprovedAccountOnlyOnce() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let otherKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 7, count: 32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let alternatives = [
                WalletAccountDescriptor(walletID: "other-wallet", account: approved.account),
                descriptor(coin: coin, key: otherKey),
                WalletAccountDescriptor(
                    walletID: approved.walletID, coin: coin,
                    normalizedAddress: approved.normalizedAddress,
                    derivationPath: coin == .ethereum ? "m/44'/60'/0'/0/1" : "m/44'/501'/1'/0'"
                ),
                descriptor(coin: coin == .ethereum ? .solana : .ethereum, key: key),
            ]
            for account in alternatives {
                let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account)
                assertUnavailable(await signer.sign(operation))
            }

            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            try assertWalletSigningSuccessForTesting(await signer.sign(operation), account: approved.account)
            assertUnavailable(await signer.sign(operation))
        }
    }

    func testFailedSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
        let malformed = try approvedWalletSigningOperationForTesting(
            approvedAccount: approved,
            payload: .ethereumTypedData(WalletCoreProxyTestVectors.malformedTypedDataJSON)
        )
        guard case .failure(.failedToSign) = await signer.sign(malformed) else {
            return XCTFail("Malformed typed data must fail cryptographic signing")
        }
        let valid = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        assertUnavailable(await signer.sign(valid))
    }

    func testConcurrentAttemptsCanProduceOnlyOneSignature() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        let first = Task { await signer.sign(operation) }
        let second = Task { await signer.sign(operation) }
        let results = await [first.value, second.value]
        var signatures = 0
        for result in results {
            switch result {
            case .success:
                signatures += 1
                try assertWalletSigningSuccessForTesting(result, account: approved.account)
            case .failure:
                assertUnavailable(result)
            }
        }
        XCTAssertEqual(signatures, 1)
        assertUnavailable(await signer.sign(operation))
    }

    func testInvalidationReleasesUnusedSigningAuthority() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            signer.invalidate()
            signer.invalidate()
            assertUnavailable(await signer.sign(operation))
        }
    }

    func testCancellationBeforeSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            let task = Task { await signer.sign(operation) }
            task.cancel()
            assertUnavailable(await task.value)
            assertUnavailable(await signer.sign(operation))
        }
    }

    func testWalletContainerIsReleasedBeforeItsApprovedKeySigns() async throws {
        for coin: WalletCoin in [.ethereum, .solana] {
            for mnemonic in [false, true] {
                weak var releasedWallet: WalletContainer?
                let (approved, signer) = try autoreleasepool {
                    let password = Data("account-signer-tests".utf8)
                    let key = try XCTUnwrap(mnemonic
                        ? WalletStoredKey.importHDWallet(
                            mnemonic: WalletCoreProxyTestVectors.multiAccountMnemonic,
                            name: "Signer", password: password, coin: coin
                        )
                        : WalletStoredKey.importPrivateKey(
                            privateKey: Data(1...32), name: "Signer", password: password, coin: coin
                        ))
                    let wallet = WalletContainer(id: "released-wallet", key: key)
                    releasedWallet = wallet
                    let account = try XCTUnwrap(wallet.accounts.first)
                    let approved = WalletAccountDescriptor(walletID: wallet.id, account: account)
                    let signer = try XCTUnwrap(UnlockedAccountSigner(
                        approvedAccount: approved,
                        privateKey: wallet.privateKey(passwordData: password, account: account)
                    ))
                    return (approved, signer)
                }
                XCTAssertNil(releasedWallet)
                let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
                try assertWalletSigningSuccessForTesting(await signer.sign(operation), account: approved.account)
                assertUnavailable(await signer.sign(operation))
            }
        }
    }

    private func descriptor(coin: WalletCoin, key: WalletPrivateKey) -> WalletAccountDescriptor {
        WalletAccountDescriptor(
            walletID: "approved-wallet", coin: coin,
            normalizedAddress: coin.normalizedAddress(WalletCrypto.addressFromPublicKeyData(
                key.publicKeyData(coin: coin), coin: coin
            )),
            derivationPath: coin == .ethereum ? "m/44'/60'/0'/0/0" : "m/44'/501'/0'/0'"
        )
    }

    private func assertUnavailable(
        _ result: Result<WalletSigningOutput, WalletSigningFailure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Expected unavailable signing authorization", file: file, line: line)
        }
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

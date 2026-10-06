import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class WalletSigningSessionTests: XCTestCase {
    func testAuthorityValidationKeepsMainActorResponsiveWhileStoreIsLocked() async throws {
        let operation = try operation()
        let material = SessionSigningMaterial()
        let sourceCheckThreads = Mutex([Bool]())
        let session = WalletSigningSession(
            material, authorization: operation.authorization,
            isCurrent: {
                sourceCheckThreads.withLock { $0.append(Thread.isMainThread) }
                return true
            }
        )
        let releaseLock = DispatchSemaphore(value: 0)
        defer { releaseLock.signal() }
        XCTAssertTrue(session.bind(operation: operation))
        sourceCheckThreads.withLock { $0.removeAll() }
        let lockHeld = expectation(description: "Approval store lock held by another worker")
        let holder = Task.detached {
            operation.withCurrentAuthority {
                lockHeld.fulfill()
                return releaseLock.wait(timeout: .now() + 5) == .success
            } ?? false
        }
        await fulfillment(of: [lockHeld], timeout: 2)
        let releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            releaseLock.signal()
        }

        let result = await session.sign()
        let released = await holder.value
        await releaseTask.value

        XCTAssertTrue(released)
        guard case .success = result else {
            return XCTFail("The main actor must release the lock before authority validation times out")
        }
        XCTAssertEqual(sourceCheckThreads.withLock { $0 }, [false, false])
        XCTAssertEqual(material.signCount, 1)
    }

    func testBindingRejectsAnotherAuthorizationAndCannotBeReplaced() async throws {
        let operation = try operation()
        let material = SessionSigningMaterial()
        let session = WalletSigningSession(
            material, authorization: operation.authorization, isCurrent: { true }
        )
        let different = try self.operation(requestID: 2)
        XCTAssertFalse(session.bind(operation: different))
        XCTAssertTrue(session.bind(operation: operation))
        XCTAssertFalse(session.bind(operation: operation))

        guard case .success = await session.sign() else {
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
        let material = SessionSigningMaterial { _ in .failure(.failedToSign) }
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
        XCTAssertTrue(session.bind(operation: operation))
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
        let material = SessionSigningMaterial()
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
        XCTAssertTrue(session.bind(operation: operation))
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
        let resolution = ApprovalResolution<Void>()
        let material = SessionSigningMaterial { operation in
            let result = walletSigningResultForTesting(operation)
            signingStarted.fulfill()
            await resolution.value()
            return result
        }
        let session = WalletSigningSession(
            material,
            authorization: operation.authorization,
            isCurrent: { true },
            acquireCommitLease: { WalletExecutionLease(release: {}) }
        )
        XCTAssertTrue(session.bind(operation: operation))
        let signing = Task { await session.sign() }
        await fulfillment(of: [signingStarted], timeout: 1)
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A duplicate attempt must not enter the active signer")
        }
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 0)
        let acquired = await session.takeCommitLease()
        let lease = try XCTUnwrap(acquired)
        XCTAssertEqual(material.erasureCount, 1)
        await resolution.resolve(())

        guard case .failure(.authorizationUnavailable) = await signing.value else {
            lease.release()
            return XCTFail("An in-flight signature must not escape after commit acquisition")
        }
        lease.release()
        session.invalidate()
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
    }

    func testApprovedPermitAndOperationEachIssueSigningAuthorityOnlyOnce() async throws {
        let (permit, operation) = try unconsumedSigningOperationForSessionTests(approvedAccount: .init(
            walletID: "session-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        XCTAssertNil(ApprovedWalletSigningOperation(permit: permit))
        let firstMaterial = SessionSigningMaterial()
        let secondMaterial = SessionSigningMaterial()
        let first = WalletSigningSession(firstMaterial, authorization: operation.authorization, isCurrent: { true })
        let second = WalletSigningSession(secondMaterial, authorization: operation.authorization, isCurrent: { true })
        let copiedOperation = operation
        XCTAssertTrue(first.bind(operation: operation))
        XCTAssertFalse(second.bind(operation: copiedOperation))
        second.invalidate()
        XCTAssertTrue(permit.consumeExecution())
        guard case .success = await first.sign(),
              case .failure(.authorizationUnavailable) = await second.sign() else {
            return XCTFail("Only the session that bound the operation may sign")
        }
        XCTAssertEqual(firstMaterial.signCount, 1)
        XCTAssertEqual(secondMaterial.signCount, 0)
    }

    func testUnstartedAndReleasedPermitsNeverCallSigningAccess() async throws {
        for released in [false, true] {
            let (permit, operation) = try unconsumedSigningOperationForSessionTests(approvedAccount: .init(
                walletID: "session-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ))
            let material = SessionSigningMaterial()
            let session = WalletSigningSession(material, authorization: operation.authorization, isCurrent: { true })
            XCTAssertTrue(session.bind(operation: operation))
            if released {
                XCTAssertTrue(permit.consumeExecution())
                permit.releaseLease()
            }
            guard case .failure(.authorizationUnavailable) = await session.sign() else {
                return XCTFail("Signing requires a started execution with its ownership lease")
            }
            XCTAssertEqual(material.signCount, 0)
        }
    }

    func testReleasedPermitDiscardsSigningAccessResult() async throws {
        let (permit, operation) = try unconsumedSigningOperationForSessionTests(approvedAccount: .init(
            walletID: "session-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        let material = SessionSigningMaterial { operation in
            let result = walletSigningResultForTesting(operation)
            permit.releaseLease()
            return result
        }
        let session = WalletSigningSession(material, authorization: operation.authorization, isCurrent: { true })
        XCTAssertTrue(session.bind(operation: operation))
        XCTAssertTrue(permit.consumeExecution())
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A result must not escape after execution ownership is released")
        }
        XCTAssertEqual(material.signCount, 1)
    }

    func testPermitReleasedDuringAuthorityCheckPreventsSigningOrDiscardsResult() async throws {
        for suspendedCheck in [1, 2] {
            let (permit, operation) = try unconsumedSigningOperationForSessionTests(approvedAccount: .init(
                walletID: "session-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ))
            let authorityCheckStarted = expectation(description: "Authority check \(suspendedCheck) started")
            let sourceCheck = WalletSigningSourceCheckGate(started: authorityCheckStarted)
            defer { sourceCheck.release() }
            let material = SessionSigningMaterial()
            let session = WalletSigningSession(
                material, authorization: operation.authorization, isCurrent: sourceCheck.check
            )
            XCTAssertTrue(session.bind(operation: operation))
            sourceCheck.arm(check: suspendedCheck)
            XCTAssertTrue(permit.consumeExecution())
            let signing = Task { await session.sign() }
            await fulfillment(of: [authorityCheckStarted], timeout: 1)
            permit.releaseLease()
            sourceCheck.release()

            guard case .failure(.authorizationUnavailable) = await signing.value else {
                return XCTFail("Ownership lost during authority check \(suspendedCheck) must invalidate signing")
            }
            XCTAssertEqual(material.signCount, suspendedCheck - 1)
            XCTAssertEqual(material.erasureCount, 1)
        }
    }

    func testSigningResultMustReturnBeforeItsDeadline() async throws {
        let deadline = Date(timeIntervalSince1970: 2_100_000_000)
        for offset: TimeInterval in [-0.001, 0, 0.001] {
            let operation = try approvedWalletSigningOperationForTesting(
                approvedAccount: WalletAccountDescriptor(
                    walletID: "session-wallet",
                    coin: .ethereum,
                    normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                    derivationPath: "m/44'/60'/0'/0/0"
                ),
                deadline: deadline
            )
            var now = deadline.addingTimeInterval(-1)
            let material = SessionSigningMaterial { operation in
                let result = walletSigningResultForTesting(operation)
                await Task.yield()
                now = deadline.addingTimeInterval(offset)
                return result
            }
            let session = WalletSigningSession(
                material,
                authorization: operation.authorization,
                isCurrent: { true },
                clock: { now }
            )
            XCTAssertTrue(session.bind(operation: operation))

            let result = await session.sign()
            if offset < 0 {
                guard case .success = result else {
                    return XCTFail("A signature returned before the deadline must be available")
                }
            } else {
                guard case .failure(.authorizationUnavailable) = result else {
                    return XCTFail("A signature returned at or after the deadline must be discarded")
                }
            }
            XCTAssertEqual(material.signCount, 1)
            XCTAssertEqual(material.erasureCount, 1)
        }
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

final class WalletSigningSourceCheckGate: Sendable {
    private struct State {
        var suspendedCheck: Int?
        var checks = 0
        var isCurrent = true
    }

    private let state = Mutex(State())
    private let started: XCTestExpectation
    private let released = DispatchSemaphore(value: 0)

    init(started: XCTestExpectation) {
        self.started = started
    }

    func arm(check: Int) {
        state.withLock {
            $0.suspendedCheck = check
            $0.checks = 0
        }
    }

    func check() -> Bool {
        let shouldSuspend = state.withLock { state in
            guard let suspendedCheck = state.suspendedCheck else { return false }
            state.checks += 1
            return state.checks == suspendedCheck
        }
        if shouldSuspend {
            started.fulfill()
            guard released.wait(timeout: .now() + 5) == .success else { return false }
        }
        return state.withLock { $0.isCurrent }
    }

    func invalidateSource() {
        state.withLock { $0.isCurrent = false }
    }

    func release() {
        released.signal()
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
                assertUnavailable(await sign(operation, using: signer))
            }

            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            try assertWalletSigningSuccessForTesting(await sign(operation, using: signer), account: approved.account)
            assertUnavailable(await sign(operation, using: signer))
        }
    }

    func testFailedSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
        let malformed = try approvedWalletSigningOperationForTesting(
            approvedAccount: approved,
            payload: .signature(.ethereumTypedData(WalletCoreProxyTestVectors.malformedTypedDataJSON))
        )
        guard case .failure(.failedToSign) = await sign(malformed, using: signer) else {
            return XCTFail("Malformed typed data must fail cryptographic signing")
        }
        let valid = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        assertUnavailable(await sign(valid, using: signer))
    }

    func testSourceIsRevalidatedOnTheWorkerImmediatelyBeforeKeyUse() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let sourceChecks = Mutex([Bool]())
        let signer = try XCTUnwrap(UnlockedAccountSigner(
            approvedAccount: approved, privateKey: key,
            sourceIsCurrent: {
                sourceChecks.withLock { $0.append(Thread.isMainThread) }
                return false
            }
        ))
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)

        assertUnavailable(await sign(operation, using: signer))
        XCTAssertEqual(sourceChecks.withLock { $0 }, [false])
        let retry = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        assertUnavailable(await sign(retry, using: signer))
        XCTAssertEqual(sourceChecks.withLock { $0.count }, 1)
    }

    func testConcurrentAttemptsCanProduceOnlyOneSignature() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        let first = Task { await sign(operation, using: signer) }
        let second = Task { await sign(operation, using: signer) }
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
        assertUnavailable(await sign(operation, using: signer))
    }

    func testOneOperationCannotSignThroughMultipleAccountSigners() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            let first = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let second = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            var secondResult: Result<WalletSigningOutput, WalletSigningFailure>?
            let result = await signingAttempt(operation) {
                let firstResult = await first.sign(operation)
                secondResult = await second.sign(operation)
                return firstResult
            }
            try assertWalletSigningSuccessForTesting(result, account: approved.account)
            assertUnavailable(try XCTUnwrap(secondResult))
        }
    }

    func testInvalidationReleasesUnusedSigningAuthority() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            signer.invalidate()
            signer.invalidate()
            assertUnavailable(await sign(operation, using: signer))
        }
    }

    func testCancellationBeforeSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            let result = await signingAttempt(operation) {
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await signer.sign(operation)
                }
                return await task.value
            }
            assertUnavailable(result)
            let nextOperation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
            assertUnavailable(await sign(nextOperation, using: signer))
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
                try assertWalletSigningSuccessForTesting(await sign(operation, using: signer), account: approved.account)
                assertUnavailable(await sign(operation, using: signer))
            }
        }
    }

    private func sign(
        _ operation: ApprovedWalletSigningOperation,
        using signer: UnlockedAccountSigner
    ) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        await signingAttempt(operation) {
            await signer.sign(operation)
        }
    }

    private func signingAttempt(
        _ operation: ApprovedWalletSigningOperation,
        signing: @escaping @MainActor @Sendable () async -> Result<WalletSigningOutput, WalletSigningFailure>
    ) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        let session = WalletSigningSession(
            SessionSigningMaterial { _ in await signing() },
            authorization: operation.authorization,
            isCurrent: { true }
        )
        guard session.bind(operation: operation) else {
            return .failure(.authorizationUnavailable)
        }
        return await session.sign()
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

@MainActor
private func unconsumedSigningOperationForSessionTests(
    approvedAccount: WalletAccountDescriptor
) throws -> (ExtensionBridge.ApprovedExecutionPermit, ApprovedWalletSigningOperation) {
    let fixture = try ApprovedExecutionTestFixture()
    try fixture.establishGrant(approvedAccount)
    let snapshot = try fixture.enqueue(
        id: 1, name: "signPersonalMessage", provider: .ethereum,
        body: ["address": approvedAccount.normalizedAddress, "chainId": "0x1", "object": ["data": "0x01"]]
    )
    let catalog = WalletReviewCatalog(
        identity: .init(generation: nil, catalogData: Data()), orderedAccounts: [approvedAccount.specificAccount]
    )
    guard case .approval(let intent) = DappRequestProcessor().prepare(try XCTUnwrap(snapshot.requestBinding), catalog: catalog) else {
        throw CocoaError(.coderInvalidValue)
    }
    let permit = try fixture.authorize(
        snapshot: snapshot, action: intent.action,
        decision: .message(.init(approvedAccount: approvedAccount, solanaCluster: nil))
    )
    return (permit, try XCTUnwrap(ApprovedWalletSigningOperation(permit: permit)))
}

private final class SessionSigningMaterial: OwnedWalletSigningAccess {
    private struct Counts: Sendable {
        var signs = 0
        var erasures = 0
    }
    private let counts = Mutex(Counts())
    private let operation: @MainActor @Sendable (ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure>

    var signCount: Int { counts.withLock { $0.signs } }
    var erasureCount: Int { counts.withLock { $0.erasures } }

    init(operation: @escaping @MainActor @Sendable (ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> = { walletSigningResultForTesting($0) }) {
        self.operation = operation
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        counts.withLock { $0.signs += 1 }
        return await self.operation(operation)
    }

    func invalidate() {
        counts.withLock { $0.erasures += 1 }
    }
}

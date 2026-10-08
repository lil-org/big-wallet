import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class WalletSigningSessionTests: XCTestCase {
    func testAuthorityValidationKeepsMainActorResponsiveWhileStoreIsLocked() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        let sourceCheckThreads = Mutex([Bool]())
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            isCurrent: {
                sourceCheckThreads.withLock { $0.append(Thread.isMainThread) }
                return true
            },
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            requiresCommitLease: false
        )
        let releaseLock = DispatchSemaphore(value: 0)
        defer { releaseLock.signal() }
        XCTAssertTrue(session.attach(permit: permit))
        sourceCheckThreads.withLock { $0.removeAll() }
        let lockHeld = expectation(description: "Approval store lock held by another worker")
        let holder = Task.detached {
            permit.withCurrentAuthority {
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

    func testAttachmentRejectsAnotherAuthorizationAndCannotBeReplaced() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            requiresCommitLease: false
        )
        let different = try self.permit(requestID: 2)
        XCTAssertFalse(session.attach(permit: different))
        let otherMaterial = SessionSigningMaterial()
        let otherSession = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: different)),
            sign: { operation, _ in await otherMaterial.sign(operation) },
            retireSigningMaterial: otherMaterial.invalidate,
            requiresCommitLease: false
        )
        XCTAssertTrue(otherSession.attach(permit: different))
        XCTAssertTrue(session.attach(permit: permit))
        XCTAssertFalse(session.attach(permit: permit))

        guard case .success = await session.sign() else {
            return XCTFail("The original authorized operation must sign")
        }
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A session must sign at most once")
        }
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
        guard case .success = await otherSession.sign() else {
            return XCTFail("A rejected scope must leave the permit available to its matching session")
        }
        XCTAssertEqual(otherMaterial.signCount, 1)
    }

    func testAttachedSessionDoesNotConsumeAReplacementPermit() async throws {
        let firstPermit = try permit()
        let replacementPermit = try permit()
        let authorization = try XCTUnwrap(WalletSigningAuthorization(permit: firstPermit))
        XCTAssertEqual(WalletSigningAuthorization(permit: replacementPermit), authorization)
        let firstMaterial = SessionSigningMaterial()
        let secondMaterial = SessionSigningMaterial()
        let first = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await firstMaterial.sign(operation) },
            retireSigningMaterial: firstMaterial.invalidate,
            requiresCommitLease: false
        )
        let second = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await secondMaterial.sign(operation) },
            retireSigningMaterial: secondMaterial.invalidate,
            requiresCommitLease: false
        )
        XCTAssertTrue(first.attach(permit: firstPermit))
        XCTAssertFalse(first.attach(permit: replacementPermit))
        XCTAssertTrue(second.attach(permit: replacementPermit))
        guard case .success = await first.sign(), case .success = await second.sign() else {
            return XCTFail("Each permit must remain with the session that successfully attached it")
        }
        XCTAssertEqual(firstMaterial.signCount, 1)
        XCTAssertEqual(secondMaterial.signCount, 1)
    }

    func testMismatchedSourceAccountDoesNotConsumePermit() async throws {
        let permit = try permit()
        let authorization = try XCTUnwrap(WalletSigningAuthorization(permit: permit))
        let material = SessionSigningMaterial()
        let mismatchedSource = TestWalletSigningSource(
            approvedAccount: WalletAccountDescriptor(
                walletID: "other-wallet", account: authorization.approvedAccount.account
            ),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate
        )
        let mismatched = WalletSigningSession(source: mismatchedSource, authorization: authorization)

        XCTAssertFalse(mismatched.attach(permit: permit))
        XCTAssertEqual(mismatchedSource.invalidationCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
        guard case .failure(.authorizationUnavailable) = await mismatched.sign() else {
            return XCTFail("A source for another account must not sign")
        }
        XCTAssertEqual(material.signCount, 0)

        let matchingSource = TestWalletSigningSource(approvedAccount: authorization.approvedAccount)
        let matching = WalletSigningSession(source: matchingSource, authorization: authorization)
        XCTAssertTrue(matching.attach(permit: permit))
        guard case .success = await matching.sign() else {
            return XCTFail("A mismatched source must leave the permit available to its matching session")
        }
        XCTAssertEqual(matchingSource.materialRetirementCount, 1)
    }

    func testInvalidationDuringAttachmentSourceCheckDoesNotConsumePermit() async throws {
        let permit = try permit()
        let authorization = try XCTUnwrap(WalletSigningAuthorization(permit: permit))
        let material = SessionSigningMaterial()
        let reference = Mutex<WalletSigningSession?>(nil)
        let invalidated = makeWalletSigningSessionForTesting(
            authorization: authorization,
            isCurrent: {
                reference.withLock { $0 }?.invalidate()
                return true
            },
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            requiresCommitLease: false
        )
        reference.withLock { $0 = invalidated }
        defer { reference.withLock { $0 = nil } }
        XCTAssertFalse(invalidated.attach(permit: permit))
        XCTAssertEqual(material.erasureCount, 1)
        let rightfulMaterial = SessionSigningMaterial()
        let rightful = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await rightfulMaterial.sign(operation) },
            retireSigningMaterial: rightfulMaterial.invalidate,
            requiresCommitLease: false
        )
        XCTAssertTrue(rightful.attach(permit: permit))
        guard case .success = await rightful.sign() else {
            return XCTFail("An invalidated session must not consume another session's permit")
        }
        XCTAssertEqual(material.signCount, 0)
        XCTAssertEqual(rightfulMaterial.signCount, 1)
    }

    func testExpiredAttachmentDoesNotConsumePermit() async throws {
        let deadline = Date().addingTimeInterval(10)
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: .init(
                walletID: "session-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ),
            deadline: deadline
        )
        let authorization = try XCTUnwrap(WalletSigningAuthorization(permit: permit))
        let expiredMaterial = SessionSigningMaterial()
        let expired = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await expiredMaterial.sign(operation) },
            retireSigningMaterial: expiredMaterial.invalidate,
            requiresCommitLease: false,
            clock: { deadline }
        )
        XCTAssertFalse(expired.attach(permit: permit))
        let currentMaterial = SessionSigningMaterial()
        let current = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await currentMaterial.sign(operation) },
            retireSigningMaterial: currentMaterial.invalidate,
            requiresCommitLease: false,
            clock: { deadline.addingTimeInterval(-1) }
        )
        XCTAssertTrue(current.attach(permit: permit))
        guard case .success = await current.sign() else {
            return XCTFail("A session's expired clock must not consume the current permit")
        }
        XCTAssertEqual(expiredMaterial.signCount, 0)
        XCTAssertEqual(currentMaterial.signCount, 1)
    }

    func testCommitLeaseDoesNotRequireASigningAttachment() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        var acquisitions = 0
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            acquireCommitLease: {
                acquisitions += 1
                return WalletExecutionLease(release: {})
            }
        )
        let acquired = await session.takeCommitLease()
        let lease = try XCTUnwrap(acquired)
        let duplicate = await session.takeCommitLease()
        XCTAssertNil(duplicate)
        XCTAssertFalse(session.attach(permit: permit))
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(material.signCount, 0)
        XCTAssertEqual(material.erasureCount, 1)
        lease.release()
    }

    func testFailedSigningErasesMaterialAndStillAllowsOneCommitLease() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial { _ in .failure(.failedToSign) }
        let released = expectation(description: "Transferred lease released")
        var acquisitions = 0
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            acquireCommitLease: {
                acquisitions += 1
                return WalletExecutionLease { released.fulfill() }
            }
        )
        XCTAssertTrue(session.attach(permit: permit))
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
        let permit = try permit()
        let material = SessionSigningMaterial()
        let acquisitionStarted = expectation(description: "Acquisition started")
        let released = expectation(description: "Late lease released")
        let resolution = ApprovalResolution<WalletExecutionLease?>()
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            acquireCommitLease: {
                acquisitionStarted.fulfill()
                return await resolution.value()
            }
        )
        XCTAssertTrue(session.attach(permit: permit))
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
        let permit = try permit()
        let signingStarted = expectation(description: "Signing started")
        let resolution = ApprovalResolution<Void>()
        let material = SessionSigningMaterial { operation in
            let result = walletSigningResultForTesting(operation)
            signingStarted.fulfill()
            await resolution.value()
            return result
        }
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            acquireCommitLease: { WalletExecutionLease(release: {}) }
        )
        XCTAssertTrue(session.attach(permit: permit))
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

    func testPermitAttachesToOnlyOneSession() async throws {
        let permit = try unconsumedSigningPermitForSessionTests(approvedAccount: .init(
            walletID: "session-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        let firstMaterial = SessionSigningMaterial()
        let secondMaterial = SessionSigningMaterial()
        let authorization = try XCTUnwrap(WalletSigningAuthorization(permit: permit))
        XCTAssertEqual(WalletSigningAuthorization(permit: permit), authorization)
        let first = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await firstMaterial.sign(operation) },
            retireSigningMaterial: firstMaterial.invalidate,
            requiresCommitLease: false
        )
        let second = makeWalletSigningSessionForTesting(
            authorization: authorization,
            sign: { operation, _ in await secondMaterial.sign(operation) },
            retireSigningMaterial: secondMaterial.invalidate,
            requiresCommitLease: false
        )
        let copiedPermit = permit
        XCTAssertTrue(first.attach(permit: permit))
        XCTAssertFalse(second.attach(permit: copiedPermit))
        XCTAssertEqual(WalletSigningAuthorization(permit: permit), authorization)
        second.invalidate()
        XCTAssertTrue(permit.consumeExecution())
        guard case .success = await first.sign(),
              case .failure(.authorizationUnavailable) = await second.sign() else {
            return XCTFail("Only the session that attached the permit may sign")
        }
        XCTAssertEqual(firstMaterial.signCount, 1)
        XCTAssertEqual(secondMaterial.signCount, 0)
    }

    func testUnstartedAndReleasedPermitsNeverCallSigningAccess() async throws {
        for released in [false, true] {
            let permit = try unconsumedSigningPermitForSessionTests(approvedAccount: .init(
                walletID: "session-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ))
            let material = SessionSigningMaterial()
            let session = makeWalletSigningSessionForTesting(
                authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                requiresCommitLease: false
            )
            XCTAssertTrue(session.attach(permit: permit))
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
        let permit = try unconsumedSigningPermitForSessionTests(approvedAccount: .init(
            walletID: "session-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        let material = SessionSigningMaterial { operation in
            let result = walletSigningResultForTesting(operation)
            permit.releaseLease()
            return result
        }
        let session = makeWalletSigningSessionForTesting(
            authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            requiresCommitLease: false
        )
        XCTAssertTrue(session.attach(permit: permit))
        XCTAssertTrue(permit.consumeExecution())
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A result must not escape after execution ownership is released")
        }
        XCTAssertEqual(material.signCount, 1)
    }

    func testPermitReleasedDuringAuthorityCheckPreventsSigningOrDiscardsResult() async throws {
        for suspendedCheck in [1, 2] {
            let permit = try unconsumedSigningPermitForSessionTests(approvedAccount: .init(
                walletID: "session-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ))
            let authorityCheckStarted = expectation(description: "Authority check \(suspendedCheck) started")
            let sourceCheck = WalletSigningSourceCheckGate(started: authorityCheckStarted)
            defer { sourceCheck.release() }
            let material = SessionSigningMaterial()
            let session = makeWalletSigningSessionForTesting(
                authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
                isCurrent: sourceCheck.check,
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                requiresCommitLease: false
            )
            XCTAssertTrue(session.attach(permit: permit))
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
            let permit = try approvedWalletSigningPermitForTesting(
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
            let session = makeWalletSigningSessionForTesting(
                authorization: try XCTUnwrap(WalletSigningAuthorization(permit: permit)),
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                requiresCommitLease: false,
                clock: { now }
            )
            XCTAssertTrue(session.attach(permit: permit))

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

    private func permit(requestID: Int = 1) throws -> ExtensionBridge.ApprovedExecutionPermit {
        try approvedWalletSigningPermitForTesting(
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
                let permit = try approvedWalletSigningPermitForTesting(approvedAccount: account)
                assertUnavailable(await sign(permit, using: signer))
            }

            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            try assertWalletSigningSuccessForTesting(await sign(permit, using: signer), account: approved.account)
            assertUnavailable(await sign(permit, using: signer))
        }
    }

    func testFailedSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
        let malformed = try approvedWalletSigningPermitForTesting(
            approvedAccount: approved,
            payload: .signature(.ethereumTypedData(WalletCoreProxyTestVectors.malformedTypedDataJSON))
        )
        guard case .failure(.failedToSign) = await sign(malformed, using: signer) else {
            return XCTFail("Malformed typed data must fail cryptographic signing")
        }
        let valid = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
        assertUnavailable(await sign(valid, using: signer))
    }

    func testSourceIsRevalidatedOnTheWorkerImmediatelyBeforeKeyUse() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let sourceChecks = Mutex([Bool]())
        let signingStarted = Mutex(false)
        let signer = try XCTUnwrap(UnlockedAccountSigner(
            approvedAccount: approved, privateKey: key
        ))
        let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)

        let result = await signingAttempt(
            permit,
            isCurrent: {
                guard signingStarted.withLock({ $0 }) else { return true }
                sourceChecks.withLock { $0.append(Thread.isMainThread) }
                return false
            }
        ) { operation, source in
            signingStarted.withLock { $0 = true }
            return await signer.sign(operation, validating: source)
        }
        assertUnavailable(result)
        XCTAssertEqual(sourceChecks.withLock { $0 }, [false])
        let retry = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
        assertUnavailable(await sign(retry, using: signer))
        XCTAssertEqual(sourceChecks.withLock { $0.count }, 1)
    }

    func testConcurrentAttemptsCanProduceOnlyOneSignature() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
        let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
        let first = Task { await sign(permit, using: signer) }
        let second = Task { await sign(permit, using: signer) }
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
        assertUnavailable(await sign(permit, using: signer))
    }

    func testOneOperationCannotSignThroughMultipleAccountSigners() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            let first = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let second = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            var secondResult: Result<WalletSigningOutput, WalletSigningFailure>?
            let result = await signingAttempt(permit) { operation, source in
                let copiedOperation = operation
                let firstResult = await first.sign(operation, validating: source)
                secondResult = await second.sign(copiedOperation, validating: source)
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
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            signer.invalidate()
            signer.invalidate()
            assertUnavailable(await sign(permit, using: signer))
        }
    }

    func testCancellationBeforeSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, privateKey: key))
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            let result = await signingAttempt(permit) { operation, source in
                let task = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await signer.sign(operation, validating: source)
                }
                return await task.value
            }
            assertUnavailable(result)
            let nextPermit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            assertUnavailable(await sign(nextPermit, using: signer))
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
                let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
                try assertWalletSigningSuccessForTesting(await sign(permit, using: signer), account: approved.account)
                assertUnavailable(await sign(permit, using: signer))
            }
        }
    }

    private func sign(
        _ permit: ExtensionBridge.ApprovedExecutionPermit,
        using signer: UnlockedAccountSigner
    ) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        await signingAttempt(permit) { operation, source in
            await signer.sign(operation, validating: source)
        }
    }

    private func signingAttempt(
        _ permit: ExtensionBridge.ApprovedExecutionPermit,
        isCurrent: @escaping @Sendable () -> Bool = { true },
        signing: @escaping TestWalletSigningSource.Signing
    ) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard let authorization = WalletSigningAuthorization(permit: permit) else {
            return .failure(.authorizationUnavailable)
        }
        let session = makeWalletSigningSessionForTesting(
            authorization: authorization,
            isCurrent: isCurrent,
            sign: signing,
            requiresCommitLease: false
        )
        guard session.attach(permit: permit) else {
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
private func unconsumedSigningPermitForSessionTests(
    approvedAccount: WalletAccountDescriptor
) throws -> ExtensionBridge.ApprovedExecutionPermit {
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
    return permit
}

private final class SessionSigningMaterial: Sendable {
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

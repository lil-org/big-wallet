import Foundation
import Synchronization
import XCTest
@testable import WalletAuthority
import WalletDomain
#if SWIFT_PACKAGE
import WalletRuntimeTestSupport
#endif

@MainActor
final class WalletSigningSessionTests: XCTestCase {
    func testAuthorityValidationKeepsMainActorResponsiveWhileStoreIsLocked() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        let sourceCheckThreads = Mutex([Bool]())
        let sessionPreparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            isCurrent: {
                sourceCheckThreads.withLock { $0.append(Thread.isMainThread) }
                return true
            },
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .native
        )
        let releaseLock = DispatchSemaphore(value: 0)
        defer { releaseLock.signal() }
        let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
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

    func testFailedConsumptionRetiresPreparationWithoutConsumingEitherPermit() async throws {
        let permit = try permit()
        let different = try self.permit(requestID: 2)
        let material = SessionSigningMaterial()
        let preparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .native
        )
        XCTAssertNil(preparation.consume(permit: different))
        XCTAssertNil(preparation.consume(permit: permit))
        XCTAssertFalse(preparation.validateCurrent())
        XCTAssertEqual(material.signCount, 0)
        XCTAssertEqual(material.erasureCount, 1)

        for untouchedPermit in [permit, different] {
            let rightful = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: untouchedPermit)), commit: .native
            )
            let session = try XCTUnwrap(rightful.consume(permit: untouchedPermit))
            guard case .success = await session.sign(),
                  case .failure(.authorizationUnavailable) = await session.sign() else {
                return XCTFail("A matching preparation must retain one signing use of the untouched permit")
            }
        }
    }

    func testAttachedSessionDoesNotConsumeAReplacementPermit() async throws {
        let firstPermit = try permit()
        let replacementPermit = try permit()
        let authorization = try XCTUnwrap(WalletSigningScope(permit: firstPermit))
        XCTAssertEqual(WalletSigningScope(permit: replacementPermit), authorization)
        let firstMaterial = SessionSigningMaterial()
        let secondMaterial = SessionSigningMaterial()
        let firstPreparation = makeWalletSigningPreparationForTesting(
            scope: authorization,
            sign: { operation, _ in await firstMaterial.sign(operation) },
            retireSigningMaterial: firstMaterial.invalidate,
            commit: .native
        )
        let secondPreparation = makeWalletSigningPreparationForTesting(
            scope: authorization,
            sign: { operation, _ in await secondMaterial.sign(operation) },
            retireSigningMaterial: secondMaterial.invalidate,
            commit: .native
        )
        let first = try XCTUnwrap(firstPreparation.consume(permit: firstPermit))
        XCTAssertNil(firstPreparation.consume(permit: replacementPermit))
        let second = try XCTUnwrap(secondPreparation.consume(permit: replacementPermit))
        guard case .success = await first.sign(), case .success = await second.sign() else {
            return XCTFail("Each permit must remain with the session that successfully attached it")
        }
        XCTAssertEqual(firstMaterial.signCount, 1)
        XCTAssertEqual(secondMaterial.signCount, 1)
    }

    func testMismatchedSourceAccountDoesNotConsumePermit() async throws {
        let permit = try permit()
        let authorization = try XCTUnwrap(WalletSigningScope(permit: permit))
        let material = SessionSigningMaterial()
        let mismatchedSource = TestWalletSigningSource(
            approvedAccount: WalletAccountDescriptor(
                walletID: "other-wallet", account: authorization.approvedAccount.account
            ),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate
        )
        let mismatched = WalletSigningPreparation(source: mismatchedSource, scope: authorization)

        XCTAssertNil(mismatched.consume(permit: permit))
        XCTAssertEqual(mismatchedSource.invalidationCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
        XCTAssertFalse(mismatched.validateCurrent())
        XCTAssertEqual(material.signCount, 0)

        let matchingSource = TestWalletSigningSource(approvedAccount: authorization.approvedAccount)
        let matchingPreparation = WalletSigningPreparation(source: matchingSource, scope: authorization)
        let matching = try XCTUnwrap(matchingPreparation.consume(permit: permit))
        guard case .success = await matching.sign() else {
            return XCTFail("A mismatched source must leave the permit available to its matching session")
        }
        XCTAssertEqual(matchingSource.materialRetirementCount, 1)
    }

    func testConsumptionTransfersOwnershipBeforeSourceValidation() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        let reference = Mutex<WalletSigningPreparation?>(nil)
        let preparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            isCurrent: {
                reference.withLock { $0 }?.invalidate()
                return true
            },
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .native
        )
        reference.withLock { $0 = preparation }
        defer { reference.withLock { $0 = nil } }
        let session = try XCTUnwrap(preparation.consume(permit: permit))
        preparation.invalidate()
        XCTAssertFalse(preparation.validateCurrent())
        XCTAssertEqual(material.erasureCount, 0)
        guard case .success = await session.sign() else {
            return XCTFail("Invalidating a consumed preparation must not invalidate its new owner")
        }
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 1)
    }

    func testCancellationDuringConsumptionRetiresSourceWithoutConsumingPermit() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        let preparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            isCurrent: {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            },
            retireSigningMaterial: material.invalidate,
            commit: .native
        )
        let consume = Task { preparation.consume(permit: permit) }
        let session = await consume.value
        XCTAssertNil(session)
        XCTAssertEqual(material.erasureCount, 1)
        XCTAssertNil(preparation.consume(permit: permit))
        let rightful = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)), commit: .native
        )
        let bound = try XCTUnwrap(rightful.consume(permit: permit))
        guard case .success = await bound.sign() else {
            return XCTFail("Cancellation during validation must leave the permit available")
        }
    }

    func testUnusedPreparationRetiresSourceWhenReleased() throws {
        let permit = try permit()
        let scope = try XCTUnwrap(WalletSigningScope(permit: permit))
        let material = SessionSigningMaterial()
        weak var released: WalletSigningPreparation?
        autoreleasepool {
            let preparation = makeWalletSigningPreparationForTesting(
                scope: scope,
                retireSigningMaterial: material.invalidate,
                commit: .native
            )
            released = preparation
            XCTAssertTrue(preparation.validateCurrent())
        }
        XCTAssertNil(released)
        XCTAssertEqual(material.erasureCount, 1)
    }

    func testConsumptionRechecksDeadlineAfterSourceValidation() async throws {
        let deadline = Date().addingTimeInterval(10)
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: .init(walletID: "session-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"),
            deadline: deadline
        )
        let scope = try XCTUnwrap(WalletSigningScope(permit: permit))
        let clock = TestClock(date: deadline.addingTimeInterval(-1))
        let material = SessionSigningMaterial()
        let preparation = makeWalletSigningPreparationForTesting(
            scope: scope,
            isCurrent: { clock.setDate(deadline); return true },
            retireSigningMaterial: material.invalidate,
            commit: .native,
            clock: { clock.date }
        )
        XCTAssertNil(preparation.consume(permit: permit))
        XCTAssertEqual(material.erasureCount, 1)
        let current = makeWalletSigningPreparationForTesting(
            scope: scope, commit: .native, clock: { deadline.addingTimeInterval(-1) }
        )
        let session = try XCTUnwrap(current.consume(permit: permit))
        guard case .success = await session.sign() else {
            return XCTFail("A source check that outlives its deadline must not consume the permit")
        }
    }

    func testPreparationTransfersItsOriginalCommitCapability() async throws {
        let permit = try permit()
        let scope = try XCTUnwrap(WalletSigningScope(permit: permit))
        let source = CommitSnapshotSource(approvedAccount: scope.approvedAccount)
        let preparation = WalletSigningPreparation(source: source, scope: scope)
        XCTAssertTrue(preparation.requiresCommitLease)
        XCTAssertTrue(preparation.requiresCommitLease)
        let session = try XCTUnwrap(preparation.consume(permit: permit))
        let outcome = await session.takeCommit()
        let lease = try walletCommitLeaseForTesting(outcome)
        lease.release()
        XCTAssertEqual(source.commitReads, 1)
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
        let authorization = try XCTUnwrap(WalletSigningScope(permit: permit))
        let expiredMaterial = SessionSigningMaterial()
        let expired = makeWalletSigningPreparationForTesting(
            scope: authorization,
            sign: { operation, _ in await expiredMaterial.sign(operation) },
            retireSigningMaterial: expiredMaterial.invalidate,
            commit: .native,
            clock: { deadline }
        )
        XCTAssertNil(expired.consume(permit: permit))
        let currentMaterial = SessionSigningMaterial()
        let currentPreparation = makeWalletSigningPreparationForTesting(
            scope: authorization,
            sign: { operation, _ in await currentMaterial.sign(operation) },
            retireSigningMaterial: currentMaterial.invalidate,
            commit: .native,
            clock: { deadline.addingTimeInterval(-1) }
        )
        let current = try XCTUnwrap(currentPreparation.consume(permit: permit))
        guard case .success = await current.sign() else {
            return XCTFail("A session's expired clock must not consume the current permit")
        }
        XCTAssertEqual(expiredMaterial.signCount, 0)
        XCTAssertEqual(currentMaterial.signCount, 1)
    }

    func testNativeCommitIsSingleUseAfterItsSourceRetires() async throws {
        for signed in [false, true] {
            let permit = try permit()
            let material = SessionSigningMaterial()
            let current = Mutex(true)
            let sourceChecks = Mutex(0)
            let sessionPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                isCurrent: {
                    sourceChecks.withLock { $0 += 1 }
                    return current.withLock { $0 }
                },
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: {
                    current.withLock { $0 = false }
                    material.invalidate()
                },
                commit: .native
            )
            let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
            if signed {
                guard case .success = await session.sign() else {
                    return XCTFail("Expected signing before source retirement")
                }
            }
            let checksBeforeCommit = sourceChecks.withLock { $0 }

            guard case .readyWithoutLease = await session.takeCommit() else {
                return XCTFail("Native commit must survive signing material retirement")
            }

            XCTAssertFalse(current.withLock { $0 })
            XCTAssertEqual(sourceChecks.withLock { $0 }, checksBeforeCommit)
            XCTAssertEqual(material.signCount, signed ? 1 : 0)
            XCTAssertEqual(material.erasureCount, 1)
            assertWalletCommitUnavailableForTesting(await session.takeCommit())
            XCTAssertNil(sessionPreparation.consume(permit: permit))
            session.invalidate()
            XCTAssertEqual(material.erasureCount, 1)
            assertWalletCommitUnavailableForTesting(await session.takeCommit())
        }
    }

    func testUnavailableVaultCommitIsConsumedWithoutLeaseFreeSuccess() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        var acquisitions = 0
        let preparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            retireSigningMaterial: material.invalidate,
            commit: .vault(acquire: {
                acquisitions += 1
                return nil
            })
        )

        let session = try XCTUnwrap(preparation.consume(permit: permit))
        assertWalletCommitUnavailableForTesting(await session.takeCommit())
        assertWalletCommitUnavailableForTesting(await session.takeCommit())

        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(material.erasureCount, 1)
        XCTAssertNil(preparation.consume(permit: permit))
    }

    func testAlreadyCancelledCommitRetiresMaterialWithoutAcquiringLease() async throws {
        for native in [false, true] {
            let permit = try permit()
            let material = SessionSigningMaterial()
            let preparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                retireSigningMaterial: material.invalidate,
                commit: native ? .native : .vault(acquire: {
                    XCTFail("An already canceled commit must not acquire a lease")
                    return WalletExecutionLease(release: {})
                })
            )
            let session = try XCTUnwrap(preparation.consume(permit: permit))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await session.takeCommit()
            }

            assertWalletCommitUnavailableForTesting(await task.value)
            assertWalletCommitUnavailableForTesting(await session.takeCommit())
            XCTAssertEqual(material.erasureCount, 1)
            XCTAssertFalse(preparation.validateCurrent())
        }
    }

    func testBoundSessionCanCommitWithoutSigning() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial()
        var acquisitions = 0
        let preparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .vault(acquire: {
                acquisitions += 1
                return WalletExecutionLease(release: {})
            })
        )
        let session = try XCTUnwrap(preparation.consume(permit: permit))
        let acquired = await session.takeCommit()
        let lease = try walletCommitLeaseForTesting(acquired)
        let duplicate = await session.takeCommit()
        assertWalletCommitUnavailableForTesting(duplicate)
        XCTAssertNil(preparation.consume(permit: permit))
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(material.signCount, 0)
        XCTAssertEqual(material.erasureCount, 1)
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("Commit acquisition must retire unused signing authority")
        }
        lease.release()
    }

    func testFailedSigningErasesMaterialAndStillAllowsOneCommitLease() async throws {
        let permit = try permit()
        let material = SessionSigningMaterial { _ in .failure(.failedToSign) }
        let released = expectation(description: "Transferred lease released")
        var acquisitions = 0
        let sessionPreparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .vault(acquire: {
                acquisitions += 1
                return WalletExecutionLease { released.fulfill() }
            })
        )
        let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
        guard case .failure(.failedToSign) = await session.sign() else {
            return XCTFail("The signing failure must be preserved")
        }
        XCTAssertEqual(material.erasureCount, 1)

        let acquired = await session.takeCommit()
        let lease = try walletCommitLeaseForTesting(acquired)
        let duplicate = await session.takeCommit()
        assertWalletCommitUnavailableForTesting(duplicate)
        XCTAssertEqual(acquisitions, 1)
        session.invalidate()
        XCTAssertEqual(material.erasureCount, 1)
        lease.release()
        await fulfillment(of: [released], timeout: 1)
    }

    func testInvalidationDisposesOfLeaseArrivingAfterAcquisitionStarted() async throws {
        for cancelTask in [false, true] {
            let permit = try permit()
            let material = SessionSigningMaterial()
            let acquisitionStarted = expectation(description: "Acquisition started")
            let released = expectation(description: "Late lease released")
            let resolution = ApprovalResolution<WalletExecutionLease?>()
            let sessionPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                commit: .vault(acquire: {
                    acquisitionStarted.fulfill()
                    return await resolution.value()
                })
            )
            let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
            let acquisition = Task { await session.takeCommit() }
            await fulfillment(of: [acquisitionStarted], timeout: 1)
            XCTAssertEqual(material.erasureCount, 1)
            if cancelTask { acquisition.cancel() } else { session.invalidate() }
            await resolution.resolve(WalletExecutionLease { released.fulfill() })

            let commit = await acquisition.value
            assertWalletCommitUnavailableForTesting(commit)
            await fulfillment(of: [released], timeout: 1)
            XCTAssertFalse(sessionPreparation.validateCurrent())
            XCTAssertEqual(material.erasureCount, 1)

        }
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
        let sessionPreparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .vault(acquire: { WalletExecutionLease(release: {}) })
        )
        let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
        let signing = Task { await session.sign() }
        await fulfillment(of: [signingStarted], timeout: 1)
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A duplicate attempt must not enter the active signer")
        }
        XCTAssertEqual(material.signCount, 1)
        XCTAssertEqual(material.erasureCount, 0)
        let acquired = await session.takeCommit()
        let lease = try walletCommitLeaseForTesting(acquired)
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
        let authorization = try XCTUnwrap(WalletSigningScope(permit: permit))
        XCTAssertEqual(WalletSigningScope(permit: permit), authorization)
        let firstPreparation = makeWalletSigningPreparationForTesting(
            scope: authorization,
            sign: { operation, _ in await firstMaterial.sign(operation) },
            retireSigningMaterial: firstMaterial.invalidate,
            commit: .native
        )
        let second = makeWalletSigningPreparationForTesting(
            scope: authorization,
            sign: { operation, _ in await secondMaterial.sign(operation) },
            retireSigningMaterial: secondMaterial.invalidate,
            commit: .native
        )
        let copiedPermit = permit
        let first = try XCTUnwrap(firstPreparation.consume(permit: permit))
        XCTAssertNil(second.consume(permit: copiedPermit))
        XCTAssertEqual(WalletSigningScope(permit: permit), authorization)
        second.invalidate()
        XCTAssertTrue(permit.consumeExecution())
        guard case .success = await first.sign() else {
            return XCTFail("Only the session that consumed the permit may sign")
        }
        XCTAssertFalse(second.validateCurrent())
        XCTAssertEqual(firstMaterial.signCount, 1)
        XCTAssertEqual(secondMaterial.signCount, 0)
    }

    func testUnstartedAndReleasedPermitsNeverCallSigningAccess() async throws {
        for released in [false, true] {
            let permit = try unconsumedSigningPermitForSessionTests(approvedAccount: .init(
                walletID: "sessionPreparation-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ))
            let material = SessionSigningMaterial()
            let sessionPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                commit: .native
            )
            let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
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
            walletID: "sessionPreparation-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        let material = SessionSigningMaterial { operation in
            let result = walletSigningResultForTesting(operation)
            permit.releaseLease()
            return result
        }
        let sessionPreparation = makeWalletSigningPreparationForTesting(
            scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
            sign: { operation, _ in await material.sign(operation) },
            retireSigningMaterial: material.invalidate,
            commit: .native
        )
        let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
        XCTAssertTrue(permit.consumeExecution())
        guard case .failure(.authorizationUnavailable) = await session.sign() else {
            return XCTFail("A result must not escape after execution ownership is released")
        }
        XCTAssertEqual(material.signCount, 1)
    }

    func testPermitReleasedDuringAuthorityCheckPreventsSigningOrDiscardsResult() async throws {
        for suspendedCheck in [1, 2] {
            let permit = try unconsumedSigningPermitForSessionTests(approvedAccount: .init(
                walletID: "sessionPreparation-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                derivationPath: "m/44'/60'/0'/0/0"
            ))
            let authorityCheckStarted = expectation(description: "Authority check \(suspendedCheck) started")
            let sourceCheck = WalletSigningSourceCheckGate(started: authorityCheckStarted)
            defer { sourceCheck.release() }
            let material = SessionSigningMaterial()
            let sessionPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                isCurrent: sourceCheck.check,
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                commit: .native
            )
            let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
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
                    walletID: "sessionPreparation-wallet",
                    coin: .ethereum,
                    normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
                    derivationPath: "m/44'/60'/0'/0/0"
                ),
                deadline: deadline
            )
            let clock = TestClock(date: deadline.addingTimeInterval(-1))
            let entered = expectation(description: "signing suspended before deadline")
            let release = TestGate<Void>()
            defer { release.resolve(()) }
            let material = SessionSigningMaterial { operation in
                let result = walletSigningResultForTesting(operation)
                entered.fulfill()
                await release.wait()
                return result
            }
            let sessionPreparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                sign: { operation, _ in await material.sign(operation) },
                retireSigningMaterial: material.invalidate,
                commit: .native,
                clock: { clock.date }
            )
            let session = try XCTUnwrap(sessionPreparation.consume(permit: permit))
            let signing = Task { await session.sign() }
            await fulfillment(of: [entered], timeout: 2)
            clock.setDate(deadline.addingTimeInterval(offset))
            release.resolve(())
            let result = await signing.value
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
                XCTAssertNil(UnlockedAccountSigner(approvedAccount: account,
                    taking: try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))))
            }
            XCTAssertNil(UnlockedAccountSigner(approvedAccount: approved,
                taking: try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 7, count: 32)))))
        }

        let invalidEthereumKey = try XCTUnwrap(WalletPrivateKey(
            data: WalletCoreProxyTestVectors.secp256k1PrivateKeyAtCurveOrder
        ))
        XCTAssertNil(UnlockedAccountSigner(
            approvedAccount: descriptor(coin: .ethereum, key: key), taking: invalidEthereumKey
        ))
    }

    func testSignerRejectsOtherAccountIdentitiesAndSignsApprovedAccountOnlyOnce() async throws {
        let otherKey = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 7, count: 32)))
        for coin: WalletCoin in [.ethereum, .solana] {
            let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: key))
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
            try assertWalletSigningSuccessForTesting(await sign(permit, using: signer), permit: permit, account: approved.account)
            assertUnavailable(await sign(permit, using: signer))
        }
    }

    func testFailedSigningConsumesTheAccountKey() async throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
        let approved = descriptor(coin: .ethereum, key: key)
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: key))
        let permit = try approvedWalletSigningPermitForTesting(
            approvedAccount: approved,
            payload: .signature(.ethereumTypedData(try XCTUnwrap(PreparedEthereumTypedData(json: WalletCoreProxyTestVectors.typedDataJSON))))
        )
        let hooks = AuthorityExecutionHooks(checkpoint: { _, _ in }, event: { event in
            if event.kind == .signingStarted { key.invalidate() }
        })
        let result = await AuthorityExecutionHooks.$current.withValue(hooks) { await sign(permit, using: signer) }
        guard case .failure(.failedToSign) = result else {
            return XCTFail("Invalidated key material must fail cryptographic signing")
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
            approvedAccount: approved, taking: key
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
        let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: key))
        let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
        let first = Task { await sign(permit, using: signer) }
        let second = Task { await sign(permit, using: signer) }
        let results = await [first.value, second.value]
        var signatures = 0
        for result in results {
            switch result {
            case .success:
                signatures += 1
                try assertWalletSigningSuccessForTesting(result, permit: permit, account: approved.account)
            case .failure:
                assertUnavailable(result)
            }
        }
        XCTAssertEqual(signatures, 1)
        assertUnavailable(await sign(permit, using: signer))
    }

    func testOneOperationCannotSignThroughMultipleAccountSigners() async throws {
        for coin: WalletCoin in [.ethereum, .solana] {
            let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
            let approved = descriptor(coin: coin, key: key)
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            let first = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: key))
            let secondKey = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
            let second = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: secondKey))
            var secondResult: Result<WalletSigningOutput, WalletSigningFailure>?
            let result = await signingAttempt(permit) { operation, source in
                let copiedOperation = operation
                let firstResult = await first.sign(operation, validating: source)
                secondResult = await second.sign(copiedOperation, validating: source)
                return firstResult
            }
            try assertWalletSigningSuccessForTesting(result, permit: permit, account: approved.account)
            assertUnavailable(try XCTUnwrap(secondResult))
        }
    }

    func testInvalidationReleasesUnusedSigningAuthority() async throws {
        for coin: WalletCoin in [.ethereum, .solana] {
            let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: key))
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
            signer.invalidate()
            signer.invalidate()
            assertUnavailable(await sign(permit, using: signer))
        }
    }

    func testCancellationBeforeSigningConsumesTheAccountKey() async throws {
        for coin: WalletCoin in [.ethereum, .solana] {
            let key = try XCTUnwrap(WalletPrivateKey(data: Data(1...32)))
            let approved = descriptor(coin: coin, key: key)
            let signer = try XCTUnwrap(UnlockedAccountSigner(approvedAccount: approved, taking: key))
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
                        taking: wallet.privateKey(passwordData: password, account: account)
                    ))
                    return (approved, signer)
                }
                XCTAssertNil(releasedWallet)
                let permit = try approvedWalletSigningPermitForTesting(approvedAccount: approved)
                try assertWalletSigningSuccessForTesting(await sign(permit, using: signer), permit: permit, account: approved.account)
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
        guard let authorization = WalletSigningScope(permit: permit) else {
            return .failure(.authorizationUnavailable)
        }
        let preparation = makeWalletSigningPreparationForTesting(
            scope: authorization,
            isCurrent: isCurrent,
            sign: signing,
            commit: .native
        )
        guard let session = preparation.consume(permit: permit) else {
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
    guard case .approval(let intent) = prepareRequestSynchronouslyForTesting(requestProcessorForTesting(), binding: try XCTUnwrap(snapshot.requestBinding), catalog: catalog) else {
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

private final class CommitSnapshotSource: WalletSigningSource {
    let approvedAccount: WalletAccountDescriptor
    private let reads = Mutex(0)
    var commitReads: Int { reads.withLock { $0 } }
    var commit: WalletSigningCommit {
        let first = reads.withLock { reads in
            reads += 1
            return reads == 1
        }
        return first ? .vault(acquire: { WalletExecutionLease(release: {}) }) : .native
    }

    init(approvedAccount: WalletAccountDescriptor) { self.approvedAccount = approvedAccount }
    func isCurrent() -> Bool { true }
    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        .failure(.failedToSign)
    }
    func retireSigningMaterial() {}
    func invalidate() {}
}

import Foundation
import LocalAuthentication
import Security
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class SigningRaceTests: XCTestCase {
    func testEveryAuthenticationResultAndReviewRetirementOrdering() async throws {
        let schedules = twoActorInterleavings(first: 2, second: 1)
        XCTAssertEqual(schedules.count, 3)
        for schedule in schedules {
            let clock = TestClock()
            let ready = TestGate<Void>()
            let biometricResult = TestGate<Void>()
            let authorityID = UUID()
            let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
            let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose,
                deadline: clock.instant + .seconds(60), clock: { clock.instant })
            let credentials = credentialFixture(authorityID: authorityID) { _ in
                ready.resolve(())
                await biometricResult.wait()
                return .succeeded
            }
            let authentication = Task { await credentials.attemptBiometrics(reason: "fixture", challenge: challenge) }
            defer { biometricResult.resolve(()); authentication.cancel(); challenge.invalidate() }
            await ready.wait()
            var grant: WalletAuthenticationGrant?
            var retired = false
            var consumed = false
            for step in schedule {
                switch (step.actor, step.index) {
                case (.first, 0):
                    biometricResult.resolve(())
                    if case .granted(let issued) = await authentication.value { grant = issued }
                case (.first, 1):
                    consumed = grant?.consume(authorityID: authorityID, purpose: purpose) == true
                    XCTAssertEqual(consumed, !retired, "Schedule: \(schedule)")
                case (.second, 0):
                    challenge.invalidate()
                    retired = true
                default: XCTFail("Unexpected schedule step")
                }
            }
            XCTAssertFalse(grant?.consume(authorityID: authorityID, purpose: purpose) == true)
            XCTAssertNil(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
            if consumed { XCTAssertNotNil(grant) }
        }
    }

    func testEveryTaskCancellationAndLateBiometricResultOrdering() async throws {
        let schedules = twoActorInterleavings(first: 1, second: 1)
        XCTAssertEqual(schedules.count, 2)
        for schedule in schedules {
            let ready = TestGate<Void>()
            let result = TestGate<Void>()
            let authorityID = UUID()
            let credentials = credentialFixture(authorityID: authorityID) { _ in
                ready.resolve(())
                await result.wait()
                return .succeeded
            }
            let challenge = credentials.makeWalletAccessChallenge()
            let authentication = Task { await credentials.attemptBiometrics(reason: "fixture", challenge: challenge) }
            defer { result.resolve(()); authentication.cancel(); challenge.invalidate() }
            await ready.wait()
            var cancelled = false
            for step in schedule {
                if step.actor == .first {
                    result.resolve(())
                    switch await authentication.value {
                    case .granted(let grant):
                        XCTAssertFalse(cancelled)
                        XCTAssertNotNil(credentials.accessSession(authorization: grant))
                    case .failed: XCTAssertTrue(cancelled)
                    case .interactionUnavailable: XCTFail("Fixture biometrics must complete")
                    }
                } else {
                    authentication.cancel()
                    cancelled = true
                }
            }
        }
    }

    func testLateBiometricSuccessCannotIssueAnElapsedChallengeAfterWallClockRollback() async throws {
        let clock = TestClock()
        let ready = TestGate<Void>()
        let result = TestGate<Void>()
        let authorityID = UUID()
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID,
            purpose: .walletAccess(UUID()), deadline: clock.instant + .seconds(150), clock: { clock.instant })
        let credentials = credentialFixture(authorityID: authorityID) { _ in
            ready.resolve(())
            await result.wait()
            return .succeeded
        }
        let authentication = Task { await credentials.attemptBiometrics(reason: "fixture", challenge: challenge) }
        defer { result.resolve(()); authentication.cancel(); challenge.invalidate() }
        await ready.wait()
        clock.setDate(.distantPast)
        clock.advanceUptime(by: 150_000_000_000)
        result.resolve(())
        guard case .failed = await authentication.value else { return XCTFail("Elapsed authentication must discard biometric success") }
        XCTAssertFalse(challenge.isPending(for: authorityID))
    }

    func testEveryLateLeaseAndSessionInvalidationOrdering() async throws {
        try await exerciseLeaseSchedules(cancelTask: false)
    }

    func testEveryLateLeaseAndTaskCancellationOrdering() async throws {
        try await exerciseLeaseSchedules(cancelTask: true)
    }

    private func exerciseLeaseSchedules(cancelTask: Bool) async throws {
        let schedules = twoActorInterleavings(first: 3, second: 3)
        XCTAssertEqual(schedules.count, 20)
        for (index, schedule) in schedules.enumerated() {
            let clock = TestClock()
            let releases = Mutex(0)
            let retirements = Mutex(0)
            let acquisitions = Mutex(0)
            let signing = Mutex(0)
            let acquisitionEntered = TestGate<Void>()
            let acquisitionResult = TestGate<WalletExecutionLease?>()
            let transferEntered = TestGate<Void>()
            let transferRelease = TestGate<Void>()
            let account = WalletAccountDescriptor(walletID: "race-wallet", coin: .ethereum,
                normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(), derivationPath: "m/44'/60'/0'/0/0")
            let permit = try approvedWalletSigningPermitForTesting(approvedAccount: account,
                deadline: clock.date.addingTimeInterval(150), requestID: index + 1)
            let preparation = makeWalletSigningPreparationForTesting(
                scope: try XCTUnwrap(WalletSigningScope(permit: permit)),
                sign: { operation, _ in
                    signing.withLock { $0 += 1 }
                    return walletSigningResultForTesting(operation)
                },
                retireSigningMaterial: { retirements.withLock { $0 += 1 } },
                commit: .vault(acquire: {
                    acquisitions.withLock { $0 += 1 }
                    acquisitionEntered.resolve(())
                    return await acquisitionResult.wait()
                }), clock: { clock.date }
            )
            let session = try await boundWalletSigningSessionForTesting(preparation, permit: permit)
            let hooks = AuthorityExecutionHooks(checkpoint: { checkpoint, _ in
                if checkpoint == .afterCommitLease {
                    transferEntered.resolve(())
                    await transferRelease.wait()
                }
            }, event: { _ in })
            let acquisition = Task { await AuthorityExecutionHooks.$current.withValue(hooks) { await session.takeCommit() } }
            defer {
                acquisitionResult.resolve(nil)
                transferRelease.resolve(())
                acquisition.cancel()
                session.invalidate()
            }
            await acquisitionEntered.wait()
            var invalidated = false
            var outcome: WalletSigningCommit.Outcome?
            for step in schedule {
                switch (step.actor, step.index) {
                case (.first, 0):
                    acquisitionResult.resolve(WalletExecutionLease { releases.withLock { $0 += 1 } })
                    await transferEntered.wait()
                case (.first, 1):
                    transferRelease.resolve(())
                    outcome = await acquisition.value
                    if invalidated { assertWalletCommitUnavailableForTesting(try XCTUnwrap(outcome)) }
                    else { _ = try walletCommitLeaseForTesting(try XCTUnwrap(outcome)) }
                case (.first, 2):
                    outcome?.releaseLease()
                    outcome?.releaseLease()
                case (.second, 0):
                    if cancelTask { acquisition.cancel() } else { session.invalidate() }
                    invalidated = true
                case (.second, 1):
                    assertWalletCommitUnavailableForTesting(await session.takeCommit())
                case (.second, 2):
                    preparation.invalidate()
                    assertWalletSigningSessionUnavailableForTesting(await preparation.consume(permit: permit))
                default: XCTFail("Unexpected schedule step")
                }
            }
            XCTAssertEqual(acquisitions.withLock { $0 }, 1, "Schedule: \(schedule)")
            XCTAssertEqual(releases.withLock { $0 }, 1, "Schedule: \(schedule)")
            XCTAssertEqual(retirements.withLock { $0 }, 1)
            XCTAssertEqual(signing.withLock { $0 }, 0)
            guard case .failure(.authorizationUnavailable) = await session.sign() else {
                return XCTFail("A committed or cancelled session cannot regain signing authority")
            }
        }
    }

    private func credentialFixture(authorityID: UUID,
        biometrics: @escaping @MainActor @Sendable (String) async -> WalletAuthenticationOutcome
    ) -> WalletCredentials {
        let keychain = Keychain(copyMatching: { query, result in
            guard (query as NSDictionary)[kSecAttrAccount] as? String == "org.lil.wallet.password" else { return errSecItemNotFound }
            result?.pointee = Data("fixture-password".utf8) as CFData
            return errSecSuccess
        }, add: { _, _ in XCTFail("Unexpected Keychain insert"); return errSecParam },
            update: { _, _ in XCTFail("Unexpected Keychain update"); return errSecParam },
            delete: { _ in XCTFail("Unexpected Keychain delete"); return errSecParam })
        let authentication = WalletCredentialAuthentication(canUseBiometrics: { true }, attemptBiometrics: biometrics)
#if os(iOS) || os(visionOS)
        let keys = SigningRaceForbiddenVaultKeys()
        let vault = SafariApprovalVault(fileURL: nil, keyStore: keys,
            canEvaluateAuthentication: { _, _ in XCTFail("Credential races must not authenticate the vault"); return false },
            authentication: { _, _, _ in XCTFail("Credential races must not authenticate the vault"); return false })
        let host = SafariApprovalVaultHost(vault: vault, integrityKeyStore: keys, sourceSnapshot: { nil })
        return WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID,
            vaultHost: host, authentication: authentication)
#else
        return WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID,
            authentication: authentication)
#endif
    }
}

#if os(iOS) || os(visionOS)
private final class SigningRaceForbiddenVaultKeys: SafariApprovalKeyStoring, SafariApprovalIntegrityKeyStoring, Sendable {
    func store(_ key: SecretBytes, identity: SafariApprovalKeyIdentity) throws {
        XCTFail("Credential races must not publish vault keys")
        throw SafariApprovalVault.Error.unavailable
    }
    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> SecretBytes {
        XCTFail("Credential races must not read vault keys")
        throw SafariApprovalVault.Error.unavailable
    }
    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        XCTFail("Credential races must not inspect vault keys")
        return [:]
    }
    func removeAll() throws { XCTFail("Credential races must not delete vault keys") }
    func loadOrCreate() throws -> SecretBytes {
        XCTFail("Credential races must not read vault integrity keys")
        throw SafariApprovalVault.Error.unavailable
    }
}
#endif

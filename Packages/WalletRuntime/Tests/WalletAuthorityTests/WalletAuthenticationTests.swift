import Foundation
import Security
import Synchronization
import WalletDomain
import XCTest
@testable import WalletAuthority

@MainActor
final class WalletAuthenticationTests: XCTestCase {
    func testConcurrentCopiesShareOneAuthorizationUse() async throws {
        let authorityID = UUID()
        let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
        let challenge = makeChallenge(authorityID: authorityID, purpose: purpose)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask { grant.consume(authorityID: authorityID, purpose: purpose) }
            }
            var accepted = 0
            for await result in group where result { accepted += 1 }
            return accepted
        }
        XCTAssertEqual(accepted, 1)
    }

    func testWrongSystemRetiresTheGrant() throws {
        let authorityID = UUID()
        let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: .devnet)
        let challenge = makeChallenge(authorityID: authorityID, purpose: purpose)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertFalse(grant.consume(authorityID: UUID(), purpose: purpose))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))
    }

    func testGrantCannotChangeItsReviewOrSelectedCluster() throws {
        let authorityID = UUID()
        let review = UUID()
        let purpose = WalletAuthenticationChallenge.Purpose.message(review: review, cluster: .devnet)
        let challenge = makeChallenge(authorityID: authorityID, purpose: purpose)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: .message(review: review, cluster: .mainnetBeta)))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))
    }

    func testCancellationDiscardsLateAuthenticationAndExistingGrant() throws {
        let authorityID = UUID()
        let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
        let late = makeChallenge(authorityID: authorityID, purpose: purpose)
        late.invalidate()
        XCTAssertNil(late.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))

        let issued = makeChallenge(authorityID: authorityID, purpose: purpose)
        let grant = try XCTUnwrap(issued.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        issued.invalidate()
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))
    }

    func testCredentialReplacementInvalidatesPendingAuthorization() throws {
        let authorityID = UUID()
        let current = Mutex(true)
        let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
        let challenge = makeChallenge(authorityID: authorityID, purpose: purpose)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { current.withLock { $0 } ? .current : .changed })))
        current.withLock { $0 = false }
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))
        current.withLock { $0 = true }
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))
    }

    func testReadAccessIsReusableButCannotBecomeSigningAuthorization() throws {
        let authorityID = UUID()
        let current = Mutex(true)
        let challenge = makeChallenge(authorityID: authorityID, purpose: .walletAccess(UUID()))
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { current.withLock { $0 } ? .current : .changed })))
        let access = try XCTUnwrap(grant.accessSession(authorityID: authorityID))
        XCTAssertTrue(access.isCurrent(for: authorityID))
        XCTAssertTrue(access.isCurrent(for: authorityID))
        XCTAssertNil(grant.accessSession(authorityID: authorityID))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: .message(review: UUID(), cluster: nil)))
        XCTAssertTrue(access.isCurrent(for: authorityID))
        current.withLock { $0 = false }
        XCTAssertFalse(access.isCurrent(for: authorityID))
        current.withLock { $0 = true }
        XCTAssertFalse(access.isCurrent(for: authorityID))
    }

    func testTransientCredentialFailurePreservesPresentationButBlocksAndRetiresPrivilegedGrants() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let credentials = fixture.credentials
        let challenge = credentials.makeWalletAccessChallenge()
        let authorityID = challenge.authorityID
        let access = try XCTUnwrap(credentials.accessSession(authorization:
            XCTUnwrap(credentials.verify(password: "password", challenge: challenge))))
        let signingPurpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
        let signingChallenge = makeChallenge(authorityID: authorityID, purpose: signingPurpose)
        let signing = try XCTUnwrap(credentials.verify(password: "password", challenge: signingChallenge))
        let binding = WalletSecretExportBinding(walletID: "wallet", account: nil, kind: .mnemonic,
            sourceDigest: Data(repeating: 1, count: 32), credentialDigest: Data(repeating: 2, count: 32))
        let exportChallenge = makeChallenge(authorityID: authorityID, purpose: .secretExport(binding))
        let export = try XCTUnwrap(credentials.verify(password: "password", challenge: exportChallenge))

        fixture.readStatus = errSecIO
        XCTAssertFalse(credentials.isCurrent(access))
        XCTAssertTrue(access.permitsAuthenticatedPresentation(for: authorityID))
        XCTAssertFalse(signing.consume(authorityID: authorityID, purpose: signingPurpose))
        XCTAssertNil(export.consumeExport(authorityID: authorityID, walletID: "wallet", account: nil, kind: .mnemonic))
        XCTAssertThrowsError(try credentials.verify(password: "password", challenge: credentials.makeWalletAccessChallenge()))

        fixture.readStatus = nil
        XCTAssertTrue(credentials.isCurrent(access))
        XCTAssertTrue(access.permitsAuthenticatedPresentation(for: authorityID))
        XCTAssertFalse(signing.consume(authorityID: authorityID, purpose: signingPurpose))
        XCTAssertNil(export.consumeExport(authorityID: authorityID, walletID: "wallet", account: nil, kind: .mnemonic))

        fixture.passwordData = Data("replacement".utf8)
        XCTAssertFalse(credentials.isCurrent(access))
        XCTAssertFalse(access.permitsAuthenticatedPresentation(for: authorityID))
        fixture.passwordData = Data("password".utf8)
        XCTAssertFalse(credentials.isCurrent(access))
        XCTAssertFalse(access.permitsAuthenticatedPresentation(for: authorityID))
    }

    func testConfirmedMissingCredentialRetiresReadAccessPermanently() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let credentials = fixture.credentials
        let challenge = credentials.makeWalletAccessChallenge()
        let access = try XCTUnwrap(credentials.accessSession(authorization:
            XCTUnwrap(credentials.verify(password: "password", challenge: challenge))))
        fixture.passwordData = nil
        XCTAssertFalse(access.permitsAuthenticatedPresentation(for: challenge.authorityID))
        fixture.passwordData = Data("password".utf8)
        XCTAssertFalse(credentials.isCurrent(access))
    }

    func testExportAuthorizationMatchesWalletAccountAndKind() throws {
        let authorityID = UUID()
        let account = WalletAccountDescriptor(walletID: "wallet", coin: .ethereum,
            normalizedAddress: "0x1111111111111111111111111111111111111111", derivationPath: "m/44'/60'/0'/0/0")
        let binding = WalletSecretExportBinding(walletID: "wallet", account: account, kind: .privateKey,
            sourceDigest: Data(repeating: 1, count: 32), credentialDigest: Data(repeating: 2, count: 32))
        let challenge = makeChallenge(authorityID: authorityID, purpose: .secretExport(binding))
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertNil(grant.consumeExport(authorityID: authorityID, walletID: "other", account: account, kind: .privateKey))
        XCTAssertNil(grant.consumeExport(authorityID: authorityID, walletID: "wallet", account: nil, kind: .mnemonic))
        XCTAssertEqual(grant.consumeExport(authorityID: authorityID, walletID: "wallet", account: account, kind: .privateKey), binding)
        XCTAssertNil(grant.consumeExport(authorityID: authorityID, walletID: "wallet", account: account, kind: .privateKey))
    }

    func testExpiredChallengeNeverIssuesOrConsumesAuthorization() throws {
        let authorityID = UUID()
        let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
        let deadline = Date(timeIntervalSince1970: 100)
        let clock = Mutex(deadline.addingTimeInterval(-1))
        let pending = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose, deadline: deadline,
            clock: { clock.withLock { $0 } })
        let issued = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose, deadline: deadline,
            clock: { clock.withLock { $0 } })
        let grant = try XCTUnwrap(issued.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        let retainedGrant = grant

        clock.withLock { $0 = deadline }
        XCTAssertNil(pending.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))

        clock.withLock { $0 = deadline.addingTimeInterval(-1) }
        XCTAssertFalse(pending.isPending(for: authorityID))
        XCTAssertNil(pending.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertFalse(retainedGrant.consume(authorityID: authorityID, purpose: purpose))
    }

    func testObservingPendingExpiryRetiresAllReferencesAfterClockRewind() {
        let authorityID = UUID()
        let deadline = Date(timeIntervalSince1970: 100)
        let clock = Mutex(deadline.addingTimeInterval(-1))
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: .walletAccess(UUID()),
            deadline: deadline, clock: { clock.withLock { $0 } })
        let retained = challenge
        XCTAssertTrue(challenge.isPending(for: authorityID))
        clock.withLock { $0 = deadline }
        XCTAssertFalse(challenge.isPending(for: authorityID))
        clock.withLock { $0 = deadline.addingTimeInterval(-1) }
        XCTAssertFalse(retained.isPending(for: authorityID))
        XCTAssertNil(retained.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
    }

    func testWrongAuthorityCheckDoesNotRetireAnotherSystemsChallenge() {
        let authorityID = UUID()
        let deadline = Date(timeIntervalSince1970: 100)
        let clock = Mutex(deadline)
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: .walletAccess(UUID()),
            deadline: deadline, clock: { clock.withLock { $0 } })
        XCTAssertFalse(challenge.isPending(for: UUID()))
        XCTAssertNil(challenge.issueGrant(for: UUID(), credentialIdentity: .init(status: { .current })))
        clock.withLock { $0 = deadline.addingTimeInterval(-1) }
        XCTAssertTrue(challenge.isPending(for: authorityID))
        XCTAssertNotNil(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
    }

    func testExpiredCredentialChallengeThrowsRatherThanReportingPasswordMismatch() throws {
        let authorityID = UUID()
        let clock = Mutex(Date(timeIntervalSince1970: 100))
        let keychain = Keychain(copyMatching: { _, _ in
            XCTFail("An expired challenge must not read credentials")
            return errSecItemNotFound
        })
        let credentials = makeCredentials(keychain: keychain, authorityID: authorityID, clock: { clock.withLock { $0 } })
        let challenge = credentials.makeWalletAccessChallenge()
        clock.withLock { $0 = Date(timeIntervalSince1970: 251) }
        XCTAssertThrowsError(try credentials.verify(password: "correct", challenge: challenge)) {
            guard case .authorizationUnavailable? = $0 as? WalletCredentialError else { return XCTFail("Expected unavailable authorization") }
        }
    }

    func testExpiryDuringCredentialReadDoesNotMintAStaleGrant() throws {
        let authorityID = UUID()
        let clock = Mutex(Date(timeIntervalSince1970: 100))
        let keychain = Keychain(copyMatching: { _, output in
            clock.withLock { $0 = Date(timeIntervalSince1970: 251) }
            output?.pointee = Data("correct".utf8) as CFData
            return errSecSuccess
        })
        let credentials = makeCredentials(keychain: keychain, authorityID: authorityID, clock: { clock.withLock { $0 } })
        let challenge = credentials.makeWalletAccessChallenge()
        XCTAssertThrowsError(try credentials.verify(password: "correct", challenge: challenge)) {
            guard case .authorizationUnavailable? = $0 as? WalletCredentialError else { return XCTFail("Expected unavailable authorization") }
        }
    }

    private func makeCredentials(
        keychain: Keychain,
        authorityID: UUID,
        clock: @escaping @Sendable () -> Date
    ) -> WalletCredentials {
#if os(iOS) || os(visionOS)
        let vault = SafariApprovalVault(fileURL: nil, clock: clock)
        let host = SafariApprovalVaultHost(vault: vault, sourceSnapshot: { nil })
        return WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID, vaultHost: host, clock: clock)
#else
        WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID, clock: clock)
#endif
    }

    private func makeChallenge(authorityID: UUID, purpose: WalletAuthenticationChallenge.Purpose) -> WalletAuthenticationChallenge {
        WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose, deadline: Date().addingTimeInterval(60))
    }
}

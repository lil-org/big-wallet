import Foundation
import Security
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
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
        XCTAssertTrue(access.validateCredentials(for: authorityID))
        XCTAssertTrue(access.validateCredentials(for: authorityID))
        XCTAssertNil(grant.accessSession(authorityID: authorityID))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: .message(review: UUID(), cluster: nil)))
        XCTAssertTrue(access.validateCredentials(for: authorityID))
        current.withLock { $0 = false }
        XCTAssertFalse(access.validateCredentials(for: authorityID))
        current.withLock { $0 = true }
        XCTAssertFalse(access.validateCredentials(for: authorityID))
    }

    func testAccessSessionExpiresAtExactIdleDeadlineWithoutRevival() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let started = ContinuousClock.now
        let clock = Mutex(started)
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock.withLock { $0 } })
        let access = try makeAccessSession(credentials: credentials)
        let retained = access

        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(900))
        clock.withLock { $0 = started + .seconds(899) }
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertTrue(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(1))

        let reads = fixture.passwordReadCount
        clock.withLock { $0 = started + .seconds(900) }
        XCTAssertNil(credentials.recordInteraction(access))
        XCTAssertFalse(credentials.validateAccess(retained))
        XCTAssertFalse(credentials.permitsAuthenticatedPresentation(retained))
        XCTAssertNil(credentials.remainingAccessLifetime(retained))

        clock.withLock { $0 = started }
        XCTAssertNil(credentials.recordInteraction(retained))
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertNil(credentials.remainingAccessLifetime(access))
        XCTAssertEqual(fixture.passwordReadCount, reads)
    }

    func testLeasePresentationLifetimeAndRenewalNeverReadCredentials() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let started = ContinuousClock.now
        let clock = Mutex(started)
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock.withLock { $0 } })
        let access = try makeAccessSession(credentials: credentials)
        let reads = fixture.passwordReadCount

        for status in [nil, errSecIO] as [OSStatus?] {
            fixture.readStatus = status
            for _ in 0..<100 {
                clock.withLock { $0 += .seconds(1) }
                XCTAssertTrue(credentials.permitsAuthenticatedPresentation(access))
                XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(899))
                XCTAssertEqual(credentials.recordInteraction(access), .seconds(900))
            }
        }
        XCTAssertEqual(fixture.passwordReadCount, reads)

        fixture.readStatus = nil
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertEqual(fixture.passwordReadCount, reads + 1)
        access.invalidate()
        XCTAssertFalse(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertNil(credentials.remainingAccessLifetime(access))
        XCTAssertNil(credentials.recordInteraction(access))
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertEqual(fixture.passwordReadCount, reads + 1)
    }

    func testInteractionRenewsTheDeadlineForEverySessionReference() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let started = ContinuousClock.now
        let clock = Mutex(started)
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock.withLock { $0 } })
        let access = try makeAccessSession(credentials: credentials)
        let retained = access

        clock.withLock { $0 = started + .seconds(899) }
        XCTAssertEqual(credentials.recordInteraction(retained), .seconds(900))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(900))
        clock.withLock { $0 = started + .seconds(900) }
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(retained), .seconds(899))
        clock.withLock { $0 = started + .seconds(1799) }
        XCTAssertNil(credentials.recordInteraction(access))
        XCTAssertNil(credentials.remainingAccessLifetime(retained))
    }

    func testAccessLifetimeIgnoresWallClockChanges() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let started = ContinuousClock.now
        let monotonic = Mutex(started)
        let wallClock = Mutex(Date(timeIntervalSince1970: 100))
        let credentials = makeCredentials(
            keychain: fixture.keychain, authorityID: UUID(),
            accessClock: { monotonic.withLock { $0 } }
        )
        let access = try makeAccessSession(credentials: credentials)

        monotonic.withLock { $0 = started + .seconds(300) }
        wallClock.withLock { $0 = .distantFuture }
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(600))
        wallClock.withLock { $0 = .distantPast }
        XCTAssertTrue(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(600))
        monotonic.withLock { $0 = started + .seconds(900) }
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertNil(credentials.remainingAccessLifetime(access))
    }

    func testUnavailableCredentialsBlockValidationButAllowLeaseRenewal() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let started = ContinuousClock.now
        let clock = Mutex(started)
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock.withLock { $0 } })
        let access = try makeAccessSession(credentials: credentials)

        clock.withLock { $0 = started + .seconds(300) }
        fixture.readStatus = errSecIO
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertTrue(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(600))
        XCTAssertEqual(credentials.recordInteraction(access), .seconds(900))
        fixture.readStatus = nil
        clock.withLock { $0 = started + .seconds(600) }
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(600))
        fixture.readStatus = errSecIO
        clock.withLock { $0 = started + .seconds(1200) }
        XCTAssertFalse(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertNil(credentials.remainingAccessLifetime(access))
        fixture.readStatus = nil
        XCTAssertNil(credentials.recordInteraction(access))
    }

    func testChangedCredentialsPermanentlyRetireAccessLifetimeAndRenewal() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID())
        let access = try makeAccessSession(credentials: credentials)

        fixture.passwordData = Data("replacement".utf8)
        let reads = fixture.passwordReadCount
        XCTAssertTrue(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertNotNil(credentials.remainingAccessLifetime(access))
        XCTAssertEqual(credentials.recordInteraction(access), .seconds(900))
        XCTAssertEqual(fixture.passwordReadCount, reads)
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertNil(credentials.remainingAccessLifetime(access))
        fixture.passwordData = Data("password".utf8)
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertNil(credentials.recordInteraction(access))
        XCTAssertFalse(credentials.permitsAuthenticatedPresentation(access))
        XCTAssertEqual(fixture.passwordReadCount, reads + 1)
    }

    func testWrongAuthorityCannotInspectRenewOrRetireAnAccessSession() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let clock = ContinuousClock.now
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock })
        let other = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock })
        let access = try makeAccessSession(credentials: credentials)
        let reads = fixture.passwordReadCount

        XCTAssertFalse(other.validateAccess(access))
        XCTAssertFalse(other.permitsAuthenticatedPresentation(access))
        XCTAssertNil(other.remainingAccessLifetime(access))
        XCTAssertNil(other.recordInteraction(access))
        XCTAssertEqual(fixture.passwordReadCount, reads)
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertEqual(credentials.remainingAccessLifetime(access), .seconds(900))
    }

    func testExpiryDuringCredentialValidationRetiresTheLease() throws {
        let started = ContinuousClock.now
        let clock = Mutex(started)
        let shouldExpire = Mutex(false)
        let keychain = Keychain(copyMatching: { _, output in
            if shouldExpire.withLock({ $0 }) {
                clock.withLock { $0 = started + .seconds(900) }
            }
            output?.pointee = Data("password".utf8) as CFData
            return errSecSuccess
        })
        let credentials = makeCredentials(keychain: keychain, authorityID: UUID(), accessClock: { clock.withLock { $0 } })
        let access = try makeAccessSession(credentials: credentials)

        clock.withLock { $0 = started + .seconds(899) }
        shouldExpire.withLock { $0 = true }
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertNil(credentials.recordInteraction(access))
        XCTAssertNil(credentials.remainingAccessLifetime(access))
        shouldExpire.withLock { $0 = false }
        clock.withLock { $0 = started }
        XCTAssertFalse(credentials.validateAccess(access))
    }

    func testConcurrentInvalidationDuringCredentialValidationPreventsAuthorizationAndRenewal() async throws {
        let entered = expectation(description: "Access validation is checking credentials")
        let release = DispatchSemaphore(value: 0)
        let shouldPause = Mutex(false)
        let keychain = Keychain(copyMatching: { _, output in
            if shouldPause.withLock({ value in
                let pause = value
                value = false
                return pause
            }) {
                entered.fulfill()
                release.wait()
            }
            output?.pointee = Data("password".utf8) as CFData
            return errSecSuccess
        })
        let credentials = makeCredentials(keychain: keychain, authorityID: UUID())
        let access = try makeAccessSession(credentials: credentials)
        let retained = access
        shouldPause.withLock { $0 = true }
        let validation = Task.detached { credentials.validateAccess(retained) }
        defer { release.signal() }

        await fulfillment(of: [entered], timeout: 5)
        access.invalidate()
        release.signal()
        let validated = await validation.value
        XCTAssertFalse(validated)
        XCTAssertNil(credentials.recordInteraction(retained))
        XCTAssertFalse(credentials.validateAccess(retained))
        XCTAssertFalse(credentials.permitsAuthenticatedPresentation(retained))
        XCTAssertNil(credentials.remainingAccessLifetime(retained))
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
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertTrue(access.permitsAuthenticatedPresentation(for: authorityID))
        XCTAssertFalse(signing.consume(authorityID: authorityID, purpose: signingPurpose))
        XCTAssertNil(export.consumeExport(authorityID: authorityID, walletID: "wallet", account: nil, kind: .mnemonic))
        XCTAssertThrowsError(try credentials.verify(password: "password", challenge: credentials.makeWalletAccessChallenge()))

        fixture.readStatus = nil
        XCTAssertTrue(credentials.validateAccess(access))
        XCTAssertTrue(access.permitsAuthenticatedPresentation(for: authorityID))
        XCTAssertFalse(signing.consume(authorityID: authorityID, purpose: signingPurpose))
        XCTAssertNil(export.consumeExport(authorityID: authorityID, walletID: "wallet", account: nil, kind: .mnemonic))

        fixture.passwordData = Data("replacement".utf8)
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertFalse(access.permitsAuthenticatedPresentation(for: authorityID))
        fixture.passwordData = Data("password".utf8)
        XCTAssertFalse(credentials.validateAccess(access))
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
        let reads = fixture.passwordReadCount
        XCTAssertTrue(access.permitsAuthenticatedPresentation(for: challenge.authorityID))
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertFalse(access.permitsAuthenticatedPresentation(for: challenge.authorityID))
        fixture.passwordData = Data("password".utf8)
        XCTAssertFalse(credentials.validateAccess(access))
        XCTAssertNil(credentials.recordInteraction(access))
        XCTAssertEqual(fixture.passwordReadCount, reads + 1)
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
        let deadline = ContinuousClock.now + .seconds(1)
        let clock = Mutex(deadline - .seconds(1))
        let pending = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose, deadline: deadline,
            clock: { clock.withLock { $0 } })
        let issued = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose, deadline: deadline,
            clock: { clock.withLock { $0 } })
        let grant = try XCTUnwrap(issued.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        let retainedGrant = grant

        clock.withLock { $0 = deadline }
        XCTAssertNil(pending.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))

        clock.withLock { $0 = deadline - .seconds(1) }
        XCTAssertFalse(pending.isPending(for: authorityID))
        XCTAssertNil(pending.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        XCTAssertFalse(retainedGrant.consume(authorityID: authorityID, purpose: purpose))
    }

    func testObservingPendingExpiryRetiresAllReferencesAfterClockRewind() {
        let authorityID = UUID()
        let deadline = ContinuousClock.now + .seconds(1)
        let clock = Mutex(deadline - .seconds(1))
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: .walletAccess(UUID()),
            deadline: deadline, clock: { clock.withLock { $0 } })
        let retained = challenge
        XCTAssertTrue(challenge.isPending(for: authorityID))
        clock.withLock { $0 = deadline }
        XCTAssertFalse(challenge.isPending(for: authorityID))
        clock.withLock { $0 = deadline - .seconds(1) }
        XCTAssertFalse(retained.isPending(for: authorityID))
        XCTAssertNil(retained.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
    }

    func testWrongAuthorityCheckDoesNotRetireAnotherSystemsChallenge() {
        let authorityID = UUID()
        let deadline = ContinuousClock.now
        let clock = Mutex(deadline)
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: .walletAccess(UUID()),
            deadline: deadline, clock: { clock.withLock { $0 } })
        XCTAssertFalse(challenge.isPending(for: UUID()))
        XCTAssertNil(challenge.issueGrant(for: UUID(), credentialIdentity: .init(status: { .current })))
        clock.withLock { $0 = deadline - .seconds(1) }
        XCTAssertTrue(challenge.isPending(for: authorityID))
        XCTAssertNotNil(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
    }

    func testExpiredCredentialChallengeThrowsRatherThanReportingPasswordMismatch() throws {
        let authorityID = UUID()
        let clock = TestClock()
        let keychain = Keychain(copyMatching: { _, _ in
            XCTFail("An expired challenge must not read credentials")
            return errSecItemNotFound
        })
        let credentials = makeCredentials(keychain: keychain, authorityID: authorityID, accessClock: { clock.instant })
        let challenge = credentials.makeWalletAccessChallenge()
        clock.advanceUptime(by: 150_000_000_000)
        XCTAssertThrowsError(try credentials.verify(password: "correct", challenge: challenge)) {
            guard case .authorizationUnavailable? = $0 as? WalletCredentialError else { return XCTFail("Expected unavailable authorization") }
        }
    }

    func testExpiryDuringCredentialReadDoesNotMintAStaleGrant() throws {
        let authorityID = UUID()
        let clock = TestClock()
        let keychain = Keychain(copyMatching: { _, output in
            clock.advanceUptime(by: 150_000_000_000)
            output?.pointee = Data("correct".utf8) as CFData
            return errSecSuccess
        })
        let credentials = makeCredentials(keychain: keychain, authorityID: authorityID, accessClock: { clock.instant })
        let challenge = credentials.makeWalletAccessChallenge()
        XCTAssertThrowsError(try credentials.verify(password: "correct", challenge: challenge)) {
            guard case .authorizationUnavailable? = $0 as? WalletCredentialError else { return XCTFail("Expected unavailable authorization") }
        }
    }

    func testStandaloneChallengeLifetimeIgnoresWallClockChanges() throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("password".utf8)
        let clock = TestClock()
        let credentials = makeCredentials(keychain: fixture.keychain, authorityID: UUID(), accessClock: { clock.instant })
        let pending = credentials.makeWalletAccessChallenge()
        let issued = credentials.makeWalletAccessChallenge()
        clock.setDate(.distantFuture)
        clock.advanceUptime(by: 149_000_000_000)
        XCTAssertTrue(pending.isPending(for: pending.authorityID))
        let grant = try XCTUnwrap(credentials.verify(password: "password", challenge: issued))
        clock.setDate(.distantPast)
        XCTAssertTrue(pending.isPending(for: pending.authorityID))
        clock.advanceUptime(by: 1_000_000_000)
        XCTAssertFalse(pending.isPending(for: pending.authorityID))
        XCTAssertNil(credentials.accessSession(authorization: grant))
        XCTAssertNil(credentials.accessSession(authorization: grant))
    }

    func testExpiryDuringCredentialIdentityValidationDoesNotIssueOrConsumeGrant() throws {
        for issuing in [true, false] {
            let clock = TestClock()
            let expire = Mutex(false)
            let authorityID = UUID()
            let purpose = WalletAuthenticationChallenge.Purpose.message(review: UUID(), cluster: nil)
            let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose,
                deadline: clock.instant + .seconds(150), clock: { clock.instant })
            let identity = WalletCredentialIdentity(status: {
                if expire.withLock({ $0 }) { clock.advanceUptime(by: 150_000_000_000) }
                return .current
            })
            if issuing {
                expire.withLock { $0 = true }
                XCTAssertNil(challenge.issueGrant(for: authorityID, credentialIdentity: identity))
            } else {
                let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID, credentialIdentity: identity))
                expire.withLock { $0 = true }
                XCTAssertFalse(grant.consume(authorityID: authorityID, purpose: purpose))
            }
            XCTAssertFalse(challenge.isPending(for: authorityID))
            XCTAssertNil(challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current })))
        }
    }

    func testNativeChallengeReplacementCannotExtendTheReviewDeadline() throws {
        let clock = TestClock()
        let review = try nativeMessageReview(clock: clock)
        defer { review.invalidate() }
        clock.advanceUptime(by: 100_000_000_000)
        clock.setDate(clock.date.addingTimeInterval(-3_600))
        let first = try XCTUnwrap(review.makeMessageAuthenticationChallenge(solanaCluster: nil))
        let firstGrant = try XCTUnwrap(first.issueGrant(for: first.authorityID, credentialIdentity: .init(status: { .current })))
        clock.advanceUptime(by: 49_000_000_000)
        let replacement = try XCTUnwrap(review.makeMessageAuthenticationChallenge(solanaCluster: nil))
        XCTAssertFalse(firstGrant.consume(authorityID: first.authorityID, purpose: first.purpose))
        let grant = try XCTUnwrap(replacement.issueGrant(for: replacement.authorityID, credentialIdentity: .init(status: { .current })))
        clock.advanceUptime(by: 1_000_000_000)
        XCTAssertFalse(grant.consume(authorityID: replacement.authorityID, purpose: replacement.purpose))
        let expired = try XCTUnwrap(review.makeMessageAuthenticationChallenge(solanaCluster: nil))
        XCTAssertFalse(expired.isPending(for: expired.authorityID))
        XCTAssertNil(expired.issueGrant(for: expired.authorityID, credentialIdentity: .init(status: { .current })))
    }

    func testNativeChallengeAlsoExpiresAtTheAbsoluteRequestDeadline() throws {
        let clock = TestClock()
        let review = try nativeMessageReview(clock: clock)
        defer { review.invalidate() }
        let challenge = try XCTUnwrap(review.makeMessageAuthenticationChallenge(solanaCluster: nil))
        let grant = try XCTUnwrap(challenge.issueGrant(for: challenge.authorityID, credentialIdentity: .init(status: { .current })))
        clock.setDate(review.request.admissionDeadline)
        XCTAssertFalse(grant.consume(authorityID: challenge.authorityID, purpose: challenge.purpose))
        clock.setDate(.distantPast)
        XCTAssertFalse(grant.consume(authorityID: challenge.authorityID, purpose: challenge.purpose))
        XCTAssertFalse(challenge.isPending(for: challenge.authorityID))
    }

    func testNativeChallengePreservesTheRequestLifetimeBeyondStandaloneExpiry() throws {
        let clock = TestClock()
        let review = try nativeMessageReview(clock: clock, admissionLifetime: ExtensionBridge.requestTTL)
        defer { review.invalidate() }
        clock.advanceUptime(by: 150_000_000_000)
        let challenge = try XCTUnwrap(review.makeMessageAuthenticationChallenge(solanaCluster: nil))
        XCTAssertTrue(challenge.isPending(for: challenge.authorityID))
        clock.advanceUptime(by: 749_000_000_000)
        XCTAssertTrue(challenge.isPending(for: challenge.authorityID))
        clock.advanceUptime(by: 1_000_000_000)
        XCTAssertFalse(challenge.isPending(for: challenge.authorityID))
    }

    func testNativeReviewCapsItsElapsedLifetimeAtTheAdmittedRequestHorizon() throws {
        let clock = TestClock()
        let review = try nativeMessageReview(clock: clock, beforeReview: { clock.setDate(.distantPast) })
        defer { review.invalidate() }
        let challenge = try XCTUnwrap(review.makeMessageAuthenticationChallenge(solanaCluster: nil))
        let horizon = UInt64((ExtensionBridge.requestTTL + ExtensionBridge.admissionDeadlineFutureSkew) * 1_000_000_000)
        clock.advanceUptime(by: horizon - 1)
        XCTAssertTrue(challenge.isPending(for: challenge.authorityID))
        clock.advanceUptime(by: 1)
        XCTAssertFalse(challenge.isPending(for: challenge.authorityID))
    }

    func testNativeReviewRechecksDeadlinesAfterCredentialValidation() throws {
        for expiration in ["none", "continuous", "absolute"] {
            let clock = TestClock()
            let authorityID = UUID()
            let validateReview = Mutex(false)
            let validations = Mutex(0)
            let accessChallenge = WalletAuthenticationChallenge(authorityID: authorityID,
                purpose: .walletAccess(UUID()), deadline: clock.instant + .seconds(150), clock: { clock.instant })
            let grant = try XCTUnwrap(accessChallenge.issueGrant(for: authorityID, credentialIdentity: .init(status: {
                if validateReview.withLock({ $0 }) {
                    validations.withLock { $0 += 1 }
                    if expiration == "continuous" { clock.advanceUptime(by: 150_000_000_000) }
                    if expiration == "absolute" { clock.setDate(clock.date.addingTimeInterval(150)) }
                }
                return .current
            })))
            let access = try XCTUnwrap(grant.accessSession(authorityID: authorityID, accessClock: { clock.instant }))
            let fixture = try ApprovedExecutionTestFixture(now: clock.date)
            let snapshot = try fixture.enqueue(id: 43, name: "requestAccounts", provider: .ethereum,
                body: ["address": ""])
            let binding = try XCTUnwrap(snapshot.requestBinding)
            let action = DappRequestAction.selectAccount(.init(coinType: .ethereum, selectedAccounts: [],
                initiallyConnectedProviders: [], network: AuthorityTestNetworks.ethereum))
            let intent = try reviewIntentForTesting(binding: binding, action: action)
            let owner = try XCTUnwrap(NativeDeliveryOwner(runtimeInstanceIdentifier: UUID(), processIdentifier: 1,
                processStartDate: clock.date, bundleURL: URL(fileURLWithPath: "/Applications/Wallet.app"),
                marketingVersion: "1", buildVersion: "1"))
            let receipt = NativeDeliveryReceipt(nativeDeliveryNonce: snapshot.nativeDeliveryNonce, owner: owner)
            let review = NativeApprovalReview(intent: intent, authorityID: authorityID, clock: { clock.date },
                monotonicClock: { clock.instant }, access: access, receipt: receipt)
            defer { review.invalidate() }

            validateReview.withLock { $0 = true }
            let operation = review.approveAccounts([], ethereumNetwork: nil)

            XCTAssertEqual(operation != nil, expiration == "none", expiration)
            XCTAssertEqual(validations.withLock { $0 }, 1, expiration)
        }
    }

    private func nativeMessageReview(clock: TestClock, admissionLifetime: TimeInterval = 150,
                                     beforeReview: () -> Void = {}) throws -> NativeApprovalReview {
        let fixture = try ApprovedExecutionTestFixture(now: clock.date)
        let account = WalletAccountDescriptor(walletID: "authentication-wallet", coin: .ethereum,
            normalizedAddress: "0x1111111111111111111111111111111111111111", derivationPath: "m/44'/60'/0'/0/0")
        try fixture.establishGrant(account)
        let snapshot = try fixture.enqueue(id: 42, name: "signPersonalMessage", provider: .ethereum,
            body: ["address": account.normalizedAddress, "object": ["data": "0x6869"]], admissionLifetime: admissionLifetime)
        let binding = try XCTUnwrap(snapshot.requestBinding)
        let action = try reviewActionForTesting(binding: binding, decision: .message(.init(approvedAccount: account, solanaCluster: nil)))
        let intent = try reviewIntentForTesting(binding: binding, action: action)
        beforeReview()
        return NativeApprovalReview(intent: intent, clock: { clock.date }, monotonicClock: { clock.instant })
    }

    private func makeCredentials(
        keychain: Keychain,
        authorityID: UUID,
        accessClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> WalletCredentials {
#if os(iOS) || os(visionOS)
        let vault = SafariApprovalVault(fileURL: nil)
        let host = SafariApprovalVaultHost(vault: vault, sourceSnapshot: { nil })
        return WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID, vaultHost: host, accessClock: accessClock)
#else
        WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID, accessClock: accessClock)
#endif
    }

    private func makeAccessSession(credentials: WalletCredentials) throws -> WalletAccessSession {
        let challenge = credentials.makeWalletAccessChallenge()
        let grant = try XCTUnwrap(credentials.verify(password: "password", challenge: challenge))
        return try XCTUnwrap(credentials.accessSession(authorization: grant))
    }

    private func makeChallenge(authorityID: UUID, purpose: WalletAuthenticationChallenge.Purpose) -> WalletAuthenticationChallenge {
        WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose, deadline: .now + .seconds(60))
    }
}

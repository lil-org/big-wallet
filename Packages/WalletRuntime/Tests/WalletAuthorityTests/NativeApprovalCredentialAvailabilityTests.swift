import Foundation
import Security
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority
@testable import WalletFlows

@MainActor
extension NativeApprovalCoordinatorTests {
    func testApprovalPresentationDoesNotReadCredentialsButConsentValidatesAccess() async throws {
        let keychain = PasswordKeychainFixture()
        keychain.passwordData = Data("password".utf8)
        let authorityID = NativeApprovalTestAuthorization.authorityID
#if os(iOS) || os(visionOS)
        let vault = SafariApprovalVault(fileURL: nil)
        let host = SafariApprovalVaultHost(vault: vault, sourceSnapshot: { nil })
        let credentials = WalletCredentials(keychain: keychain.keychain, messages: .testingEnglish,
            authorityID: authorityID, vaultHost: host)
#else
        let credentials = WalletCredentials(keychain: keychain.keychain, messages: .testingEnglish, authorityID: authorityID)
#endif
        let challenge = credentials.makeWalletAccessChallenge()
        let grant = try XCTUnwrap(credentials.verify(password: "password", challenge: challenge))
        let access = try XCTUnwrap(credentials.accessSession(authorization: grant))
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            XCTFail("Unavailable credentials must block consent")
            return .responseReady
        })
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let authenticationReads = keychain.passwordReadCount
        fixture.coordinator.resumeAfterAuthentication(authorization: access)
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(keychain.passwordReadCount, authenticationReads + 1)
        let review = try presentedReview(fixture.coordinator)
        let reads = keychain.passwordReadCount
        keychain.readStatus = errSecIO

        for _ in 0..<100 {
            XCTAssertTrue(fixture.coordinator.hasAuthenticated)
            XCTAssertTrue(fixture.coordinator.canReactivate)
            XCTAssertFalse(fixture.coordinator.isDormant)
            XCTAssertTrue(try presentedReview(fixture.coordinator) === review)
        }
        XCTAssertEqual(keychain.passwordReadCount, reads)

        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: review)
        XCTAssertEqual(keychain.passwordReadCount, reads + 1)
        XCTAssertFalse(review.isActive)
        await waitForState(fixture.coordinator, .finished)
    }

    func testApprovalRejectsWhenCredentialsBecomeUnavailableOrChanged() async throws {
        for unavailable in [WalletCredentialIdentity.Status.unavailable, .changed] {
            let status = Mutex(WalletCredentialIdentity.Status.current)
            let decisions = Mutex(0)
            let rejected = Mutex(0)
            let authorityID = NativeApprovalTestAuthorization.authorityID
            let challenge = WalletAuthenticationChallenge(authorityID: authorityID,
                purpose: .walletAccess(UUID()), deadline: .distantFuture)
            let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID,
                credentialIdentity: .init(status: { status.withLock { $0 } })))
            let access = try XCTUnwrap(grant.accessSession(authorityID: authorityID))
            let fixture = try makeFixture(attemptNativeDecision: { _ in
                decisions.withLock { $0 += 1 }
                return .responseReady
            })
            fixture.store.rejectHandler = { handle, nonce, owner in
                XCTAssertEqual(handle, fixture.key.handle)
                XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
                XCTAssertEqual(owner, fixture.runtime)
                rejected.withLock { $0 += 1 }
                return .persisted
            }
            fixture.store.unownedRejectHandler = { _ in
                XCTFail("An authenticated review must reject only its exact receipt")
                return .ownershipLost
            }
            defer { fixture.store.rejectHandler = { _, _, _ in .ownershipLost } }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: access)
            await waitForState(fixture.coordinator, .reviewing)
            let review = try presentedReview(fixture.coordinator)

            status.withLock { $0 = unavailable }
            fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: review)
            XCTAssertEqual(fixture.coordinator.phase, .rejecting)
            XCTAssertFalse(review.isActive)
            XCTAssertEqual(decisions.withLock { $0 }, 0)
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(rejected.withLock { $0 }, 1)
            XCTAssertEqual(decisions.withLock { $0 }, 0)
            XCTAssertFalse(review.isActive)
        }
    }

    func testSigningCredentialFailureAfterAuthenticationRetiresReviewAndRejects() async throws {
        let account = WalletAccount(address: "0x0000000000000000000000000000000000000001",
            coin: .ethereum, derivation: .custom, derivationPath: "m/44'/60'/0'/0/0",
            publicKey: "", extendedPublicKey: "")
        let network = try XCTUnwrap(AuthorityTestNetworks.resolver.resolve(chainId: 1).resolvedNetwork)
        let transaction = Transaction(from: account.address, to: account.address, nonce: "0x1",
            gas: "0x5208", value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10))
        let actions: [DappRequestAction] = [
            .approveMessage(SignMessageAction(subject: .signPersonalMessage, walletId: "wallet", account: account,
                meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8))))),
            .approveTransaction(SendTransactionAction(transaction: transaction, resolvedNetwork: network,
                walletId: "wallet", account: account)),
        ]
        for action in actions {
            for invalidatesAccess in [true, false] {
                for unavailable in [WalletCredentialIdentity.Status.unavailable, .changed] {
                    let status = Mutex(WalletCredentialIdentity.Status.current)
                    let authorityID = NativeApprovalTestAuthorization.authorityID
                    let accessChallenge = WalletAuthenticationChallenge(authorityID: authorityID,
                        purpose: .walletAccess(UUID()), deadline: .distantFuture)
                    let accessGrant = try XCTUnwrap(accessChallenge.issueGrant(for: authorityID,
                        credentialIdentity: .init(status: { invalidatesAccess ? status.withLock { $0 } : .current })))
                    let access = try XCTUnwrap(accessGrant.accessSession(authorityID: authorityID))
                    let clock = TestClock(uptimeNanoseconds: 0)
                    let waits = ScheduledWaits()
                    defer { waits.resumeAll() }
                    let fixture = try makeFixture(clock: clock, environment: .init(
                        now: { clock.date }, authorityID: authorityID,
                        uptime: { Double(clock.uptimeNanoseconds) / 1_000_000_000 }, wait: waits.wait,
                        prepare: { binding, _ in self.approvalPreparation(binding, action: action) },
                        attemptNativeDecision: { _ in XCTFail("Rejected authorization must not execute"); return .responseReady }
                    ), requestAction: action)
                    var rejections = 0
                    fixture.store.rejectHandler = { handle, nonce, owner in
                        XCTAssertEqual(handle, fixture.key.handle)
                        XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
                        XCTAssertEqual(owner, fixture.runtime)
                        rejections += 1
                        return .persisted
                    }
                    defer { fixture.store.rejectHandler = { _, _, _ in .ownershipLost } }
                    fixture.store.unownedRejectHandler = { _ in XCTFail("Reject only the owned receipt"); return .ownershipLost }
                    start(fixture)
                    await waitForState(fixture.coordinator, .awaitingAuthentication)
                    fixture.coordinator.resumeAfterAuthentication(authorization: access)
                    await waitForState(fixture.coordinator, .reviewing)
                    let review = try presentedReview(fixture.coordinator)
                    let challenge: WalletAuthenticationChallenge?
                    if case .approveMessage = action {
                        challenge = review.makeMessageAuthenticationChallenge(solanaCluster: nil)
                    } else {
                        challenge = review.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)
                    }
                    let authorization = try XCTUnwrap(try XCTUnwrap(challenge).issueGrant(for: authorityID,
                        credentialIdentity: .init(status: { status.withLock { $0 } })))
                    let participant = ReviewTeardownParticipant()
                    var teardowns = 0
                    participant.onInvalidate = { teardowns += 1 }
                    review.register(participant)

                    status.withLock { $0 = unavailable }
                    if case .approveMessage = action {
                        fixture.coordinator.approveMessage(solanaCluster: nil, review: review, authorization: authorization)
                    } else {
                        fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network, review: review, authorization: authorization)
                    }
                    XCTAssertEqual(fixture.coordinator.phase, .rejecting)
                    XCTAssertFalse(review.isActive)
                    XCTAssertEqual(teardowns, 1)
                    await waitForState(fixture.coordinator, .finished)
                    XCTAssertEqual(rejections, 1)
                    fixture.coordinator.reject(review: review)
                    XCTAssertEqual(rejections, 1)
                }
            }
        }
    }

    func testReplacedReviewCannotRejectTheCurrentRequestDuringCredentialOutage() async throws {
        let status = Mutex(WalletCredentialIdentity.Status.current)
        let authorityID = NativeApprovalTestAuthorization.authorityID
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID,
            purpose: .walletAccess(UUID()), deadline: .distantFuture)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID,
            credentialIdentity: .init(status: { status.withLock { $0 } })))
        let access = try XCTUnwrap(grant.accessSession(authorityID: authorityID))
        let rejected = Mutex(0)
        let fixture = try makeFixture(attemptNativeDecision: { _ in .reviewRequired })
        fixture.store.rejectHandler = { _, _, _ in rejected.withLock { $0 += 1 }; return .persisted }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: access)
        await waitForState(fixture.coordinator, .reviewing)
        let original = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: original)
        await waitForState(fixture.coordinator, .paused)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        let current = try presentedReview(fixture.coordinator)
        XCTAssertFalse(original === current)
        XCTAssertFalse(original.isActive)

        status.withLock { $0 = .unavailable }
        fixture.coordinator.reject(review: original)
        XCTAssertEqual(fixture.coordinator.phase, .reviewing)
        XCTAssertTrue(current.isActive)
        XCTAssertEqual(rejected.withLock { $0 }, 0)
        fixture.coordinator.reject(review: current)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejected.withLock { $0 }, 1)
    }

    func testTransientCredentialReadFailureKeepsExplicitReviewRetryVisible() async throws {
        let status = Mutex(WalletCredentialIdentity.Status.current)
        let decisions = Mutex(0)
        let authorityID = NativeApprovalTestAuthorization.authorityID
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID,
            purpose: .walletAccess(UUID()), deadline: .distantFuture)
        let grant = try XCTUnwrap(challenge.issueGrant(for: authorityID,
            credentialIdentity: .init(status: { status.withLock { $0 } })))
        let access = try XCTUnwrap(grant.accessSession(authorityID: authorityID))
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            decisions.withLock { $0 += 1 }
            status.withLock { $0 = .unavailable }
            return .reviewRequired
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: access)
        await waitForState(fixture.coordinator, .reviewing)
        let original = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: original)
        await waitForState(fixture.coordinator, .paused)

        guard case .retryRequired? = fixture.coordinator.currentPresentation?.presentation,
              case .retryRequired? = fixture.events.presentations.last else {
            return XCTFail("Temporary credential storage failure must preserve the explicit Retry presentation")
        }
        XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        XCTAssertTrue(fixture.coordinator.requiresExplicitReviewRetry)
        XCTAssertFalse(fixture.coordinator.isDormant)
        XCTAssertFalse(access.validateCredentials(for: authorityID))
        XCTAssertEqual(decisions.withLock { $0 }, 1)

        status.withLock { $0 = .current }
        XCTAssertTrue(access.validateCredentials(for: authorityID))
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        let renewed = try presentedReview(fixture.coordinator)
        XCTAssertFalse(renewed === original)
        XCTAssertFalse(original.isActive)
        XCTAssertEqual(decisions.withLock { $0 }, 1)

        status.withLock { $0 = .changed }
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: renewed)
        XCTAssertFalse(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(renewed.isActive)
        XCTAssertEqual(decisions.withLock { $0 }, 1)
        await waitForState(fixture.coordinator, .finished)
        status.withLock { $0 = .current }
        XCTAssertFalse(access.validateCredentials(for: authorityID))
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: renewed)
        XCTAssertEqual(decisions.withLock { $0 }, 1)
    }
}

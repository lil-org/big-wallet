import Foundation
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
extension NativeApprovalCoordinatorTests {
    func testAuthorityRetiresPreviousReviewAndItsIssuedGrant() async throws {
        var attempts = 0
        let fixture = try makeAuthorityBoundaryFixture(finalize: { _ in
            attempts += 1
            return .responseReady
        })
        guard case .review(let first) = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Expected the first core review")
        }
        let challenge = try XCTUnwrap(first.makeMessageAuthenticationChallenge(solanaCluster: nil))
        let grant = NativeApprovalTestAuthorization.grant(challenge)
        guard case .review(let second) = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Expected a replacement core review")
        }
        XCTAssertFalse(first.isActive)
        XCTAssertNil(first.makeMessageAuthenticationChallenge(solanaCluster: nil))
        XCTAssertNil(first.approveMessage(solanaCluster: nil, authorization: grant))
        XCTAssertEqual(attempts, 0)
        let currentGrant = NativeApprovalTestAuthorization.grant(try XCTUnwrap(second.makeMessageAuthenticationChallenge(solanaCluster: nil)))
        let operation = try XCTUnwrap(second.approveMessage(solanaCluster: nil, authorization: currentGrant))
        let result = await operation.attempt()
        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(attempts, 1)
    }

    func testAuthorityDiscardsPreparationThatFinishesAfterItsReplacement() async throws {
        let fixture = try makeAuthorityBoundaryFixture()
        let snapshot = try XCTUnwrap(fixture.store.snapshot)
        let started = expectation(description: "First core preparation is loading")
        let release = TestGate<ExtensionBridge.SnapshotResult>()
        defer { release.resolve(.missing) }
        var reads = 0
        fixture.store.loadHandler = { _ in
            reads += 1
            if reads == 1 {
                started.fulfill()
                return await release.wait()
            }
            return .found(snapshot)
        }
        let first = Task { await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) }
        await fulfillment(of: [started], timeout: 1)
        guard case .review(let current) = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Expected the newest preparation to produce a review")
        }
        release.resolve(.found(snapshot))
        guard case .unavailable = await first.value else {
            return XCTFail("A stale asynchronous preparation must not publish a review")
        }
        XCTAssertTrue(current.isActive)
        let grant = NativeApprovalTestAuthorization.grant(try XCTUnwrap(current.makeMessageAuthenticationChallenge(solanaCluster: nil)))
        XCTAssertNotNil(current.approveMessage(solanaCluster: nil, authorization: grant))
    }

    func testAuthorityAccessRebindingRetiresItsReviewAndChallenge() async throws {
        let fixture = try makeAuthorityBoundaryFixture()
        guard case .review(let first) = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Expected the original review")
        }
        let challenge = try XCTUnwrap(first.makeMessageAuthenticationChallenge(solanaCluster: nil))
        let grant = NativeApprovalTestAuthorization.grant(challenge)
        let replacement = NativeApprovalTestAuthorization.accessSession()
        XCTAssertTrue(fixture.authority.acceptAccess(replacement))
        XCTAssertFalse(first.isActive)
        XCTAssertNil(first.approveMessage(solanaCluster: nil, authorization: grant))
        guard case .unavailable = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("The replaced access session must not reopen the review")
        }
        guard case .review(let current) = await fixture.authority.prepareReview(owner: fixture.owner, access: replacement) else {
            return XCTFail("The current access session must still prepare a review")
        }
        XCTAssertTrue(current.isActive)
    }

    func testAuthorityDiscardsCancelledAsynchronousPreparation() async throws {
        let started = expectation(description: "Preparation suspended")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        var preparations = 0
        let fixture = try makeAuthorityBoundaryFixture(beforePreparation: {
            preparations += 1
            if preparations == 1 {
                started.fulfill()
                await release.wait()
            }
        })
        let preparation = Task { await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) }
        await fulfillment(of: [started], timeout: 1)
        preparation.cancel()
        release.resolve(())
        guard case .unavailable = await preparation.value else {
            return XCTFail("Cancelled asynchronous preparation must not publish a review")
        }
        guard case .review(let review) = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Fresh preparation must remain available")
        }
        XCTAssertTrue(review.isActive)
    }

    func testAuthorityRechecksRequestAfterAsynchronousPreparation() async throws {
        let started = expectation(description: "Preparation suspended")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        let fixture = try makeAuthorityBoundaryFixture(beforePreparation: {
            started.fulfill()
            await release.wait()
        })
        let preparation = Task { await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) }
        await fulfillment(of: [started], timeout: 1)
        fixture.store.snapshot = nil
        release.resolve(())
        guard case .changed = await preparation.value else {
            return XCTFail("A retired request must not be presented after asynchronous preparation")
        }
    }

    func testAuthorityDiscardsAsynchronousPreparationAfterAccessReplacement() async throws {
        let started = expectation(description: "Preparation suspended")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        let fixture = try makeAuthorityBoundaryFixture(beforePreparation: {
            started.fulfill()
            await release.wait()
        })
        let preparation = Task { await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(fixture.authority.acceptAccess(NativeApprovalTestAuthorization.accessSession()))
        release.resolve(())
        guard case .unavailable = await preparation.value else {
            return XCTFail("Access replacement must retire suspended preparation")
        }
    }

    func testAcceptedNativeOperationSurvivesPresentationRetirement() async throws {
        var attempts = 0
        let fixture = try makeAuthorityBoundaryFixture(finalize: { consent in
            attempts += 1
            XCTAssertTrue(consent.authorizationIsAvailable)
            return .responseReady
        })
        guard case .review(let first) = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Expected the original review")
        }
        let grant = NativeApprovalTestAuthorization.grant(try XCTUnwrap(first.makeMessageAuthenticationChallenge(solanaCluster: nil)))
        let operation = try XCTUnwrap(first.approveMessage(solanaCluster: nil, authorization: grant))
        guard case .review = await fixture.authority.prepareReview(owner: fixture.owner, access: fixture.access) else {
            return XCTFail("Expected replacement presentation")
        }
        XCTAssertFalse(first.isActive)
        let result = await operation.attempt()
        XCTAssertEqual(result, .responseReady)
        XCTAssertEqual(attempts, 1)
    }

    private struct AuthorityBoundaryFixture {
        let authority: NativeApprovalAuthority
        let store: CoordinatorStore
        let owner: NativeDeliveryOwner
        let access: WalletAccessSession
    }

    private func makeAuthorityBoundaryFixture(
        beforePreparation: @escaping @MainActor @Sendable () async -> Void = {},
        finalize: @escaping @MainActor @Sendable (ReviewConsent) async -> NativeApprovalFinalizationResult = { _ in .responseReady }
    ) throws -> AuthorityBoundaryFixture {
        let clock = TestClock(uptimeNanoseconds: 0)
        let key = approvalKey(id: 31_001)
        let owner = nativeOwner(runtime: UUID())
        let account = WalletAccount(address: "0x0000000000000000000000000000000000000001", coin: .ethereum,
            derivation: .custom, derivationPath: "m/44'/60'/0'/0/0", publicKey: "", extendedPublicKey: "")
        let action = DappRequestAction.approveMessage(SignMessageAction(subject: .signPersonalMessage,
            walletId: "review-wallet", account: account, meta: "reviewed",
            payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))))
        let store = CoordinatorStore()
        store.snapshot = try approvalSnapshot(handle: key.handle, nonce: key.nativeDeliveryNonce,
            deadline: clock.date.addingTimeInterval(300),
            receipt: .init(nativeDeliveryNonce: key.nativeDeliveryNonce, owner: owner), action: action)
        let authority = NativeApprovalAuthority(handle: key.handle, nativeDeliveryNonce: key.nativeDeliveryNonce,
            store: store, environment: .init(now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { Double(clock.uptimeNanoseconds) / 1_000_000_000 }, wait: { _ in },
                prepare: { binding, _ in
                    await beforePreparation()
                    return self.approvalPreparation(binding, action: action)
                }, attemptNativeDecision: finalize))
        let access = NativeApprovalTestAuthorization.accessSession()
        XCTAssertTrue(authority.acceptAccess(access))
        return AuthorityBoundaryFixture(authority: authority, store: store, owner: owner, access: access)
    }
}

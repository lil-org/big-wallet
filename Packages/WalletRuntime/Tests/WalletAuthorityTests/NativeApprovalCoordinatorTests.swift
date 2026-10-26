import Foundation
import XCTest
import WalletDomain
@testable import WalletAuthority
import WalletRuntimeTestSupport

@MainActor
final class NativeApprovalCoordinatorTests: XCTestCase {
    func testSigningDecisionsCaptureTheAccountFromTheReviewedPresentation() async throws {
        let account = WalletAccount(
            address: "0x0000000000000000000000000000000000000001",
            coin: .ethereum,
            derivation: .custom,
            derivationPath: "m/44'/60'/0'/0/7",
            publicKey: "",
            extendedPublicKey: ""
        )
        let approvedAccount = WalletAccountDescriptor(walletID: "reviewed-wallet", account: account)
        let network = ResolvedEthereumNetwork(network: EthereumNetwork(
            chainId: 1, name: "Ethereum", symbol: "ETH",
            rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
            isTestnet: false, mightShowPrice: true, explorer: nil
        ), source: .custom)
        let transaction = Transaction(
            from: account.address, to: account.address, nonce: "0x1", gas: "0x5208",
            value: "0x0", data: "0x", preparedFee: .legacy(gasPrice: 10)
        )
        let actions: [DappRequestAction] = [
            .approveMessage(SignMessageAction(
                subject: .signPersonalMessage, walletId: approvedAccount.walletID,
                account: account, meta: "reviewed", payload: .signature(.ethereumPersonalMessage(Data("reviewed".utf8)))
            )),
            .approveTransaction(SendTransactionAction(
                transaction: transaction, resolvedNetwork: network,
                walletId: approvedAccount.walletID, account: account
            )),
        ]
        for action in actions {
            let clock = TestClock(uptimeNanoseconds: 0)
            let waits = ScheduledWaits()
            var decisions = 0
            var capturedDecision: DappApprovalDecision?
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
                prepare: { binding, _ in self.approvalPreparation(binding, action: action) },
                attemptNativeDecision: { authorization in
                    decisions += 1
                    capturedDecision = authorization.decision
                    return .responseReady
                }
            ), requestAction: action)
            defer { waits.resumeAll() }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await waitForState(fixture.coordinator, .reviewing)
            let nativeReview = try presentedReview(fixture.coordinator)
            await waitForScheduledWait(waits, count: 1)
            let foreignReview = try nativeReviewForTesting()
            fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: foreignReview)
            fixture.coordinator.approveMessage(solanaCluster: nil, review: foreignReview, authorization: NativeApprovalTestAuthorization.grant(foreignReview.makeMessageAuthenticationChallenge(solanaCluster: nil)))
            fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network, review: foreignReview, authorization: NativeApprovalTestAuthorization.grant(foreignReview.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)))
            fixture.coordinator.approveAddEthereumChain(review: foreignReview)
            fixture.coordinator.reject(review: foreignReview)
            XCTAssertEqual(fixture.coordinator.phase, .reviewing)
            XCTAssertTrue(nativeReview.isActive)
            XCTAssertTrue(foreignReview.isActive)
            switch action {
            case .approveMessage:
                fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network, review: nativeReview, authorization: NativeApprovalTestAuthorization.grant(nativeReview.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)))
                XCTAssertEqual(fixture.coordinator.phase, .reviewing)
                fixture.coordinator.approveMessage(solanaCluster: nil, review: nativeReview, authorization: NativeApprovalTestAuthorization.grant(nativeReview.makeMessageAuthenticationChallenge(solanaCluster: nil)))
            case .approveTransaction:
                fixture.coordinator.approveMessage(solanaCluster: nil, review: nativeReview, authorization: NativeApprovalTestAuthorization.grant(nativeReview.makeMessageAuthenticationChallenge(solanaCluster: nil)))
                XCTAssertEqual(fixture.coordinator.phase, .reviewing)
                fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network, review: nativeReview, authorization: NativeApprovalTestAuthorization.grant(nativeReview.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)))
            default:
                return XCTFail("Expected signing action")
            }
            await waitForState(fixture.coordinator, .finished)

            switch try XCTUnwrap(capturedDecision) {
            case .message(let decision):
                XCTAssertEqual(decision.approvedAccount, approvedAccount)
            case .transaction(let decision):
                XCTAssertEqual(decision.approvedAccount, approvedAccount)
            default:
                XCTFail("Expected an account-bound signing decision")
            }
            XCTAssertEqual(decisions, 1)
        }
    }


    func testReviewLifetimeInvalidatesBeforeCleanupAndDoesNotRetainParticipants() async throws {
        let lifetime = try nativeReviewForTesting()
        var cleanupCount = 0
        let participant = ReviewTeardownParticipant()
        participant.onInvalidate = {
            XCTAssertFalse(lifetime.isActive)
            cleanupCount += 1
            lifetime.invalidate()
        }
        lifetime.register(participant)
        lifetime.register(participant)
        var discarded: ReviewTeardownParticipant? = ReviewTeardownParticipant()
        weak let weakDiscarded = discarded
        lifetime.register(discarded!)
        discarded = nil
        XCTAssertNil(weakDiscarded)

        lifetime.invalidate()
        lifetime.invalidate()
        XCTAssertEqual(cleanupCount, 1)

        let late = ReviewTeardownParticipant()
        late.onInvalidate = { cleanupCount += 1; XCTAssertFalse(lifetime.isActive) }
        lifetime.register(late)
        XCTAssertEqual(cleanupCount, 2)
    }


    func testReviewLifetimeKeepsAllParticipantsAliveUntilCleanupFinishes() async throws {
        let lifetime = try nativeReviewForTesting()
        let first = ReviewTeardownParticipant()
        var second: ReviewTeardownParticipant? = ReviewTeardownParticipant()
        weak let weakSecond = second
        var cleanedSecond = false
        first.onInvalidate = { second = nil }
        second?.onInvalidate = { cleanedSecond = true }
        lifetime.register(first)
        lifetime.register(second!)

        lifetime.invalidate()

        XCTAssertTrue(cleanedSecond)
        XCTAssertNil(weakSecond)
    }


    func testReviewTeardownPrecedesNotificationAndPreservesAcceptedConsent() async throws {
        var consent: ReviewConsent?
        let fixture = try makeFixture(attemptNativeDecision: {
            consent = $0
            return .responseReady
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let review = try presentedReview(fixture.coordinator)
        let revision = try XCTUnwrap(fixture.coordinator.currentPresentation?.revision)
        let participant = ReviewTeardownParticipant()
        var teardownCount = 0
        var waitingNotifications = 0
        participant.onInvalidate = {
            teardownCount += 1
            XCTAssertFalse(review.isActive)
            XCTAssertEqual(fixture.coordinator.phase, .waiting)
            XCTAssertGreaterThan(fixture.coordinator.currentPresentation?.revision ?? 0, revision)
            guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
                return XCTFail("The replacement must be published before review teardown")
            }
            fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: review)
            fixture.coordinator.reject(review: review)
        }
        review.register(participant)
        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator] event in
            guard case .presentationChanged = event,
                  case .waiting? = coordinator?.currentPresentation?.presentation else { return }
            waitingNotifications += 1
            XCTAssertEqual(teardownCount, 1)
        }
        defer { fixture.coordinator.onEvent = nil }

        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: review)
        XCTAssertEqual(teardownCount, 1)
        XCTAssertEqual(waitingNotifications, 1)
        await waitForState(fixture.coordinator, .finished)

        XCTAssertTrue(try XCTUnwrap(consent).authorizationIsAvailable)
        XCTAssertEqual(teardownCount, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testReviewTeardownReentryPublishesOnlyTheReplacementRecoveryState() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let outage = LockedTestValue(false)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { Double(clock.uptimeNanoseconds) / 1_000_000_000 },
            wait: { delay in
                if outage.value {
                    clock.advanceUptime(by: delay)
                    await Task.yield()
                } else {
                    await waits.wait(delay)
                }
            },
            prepare: { binding, _ in self.approvalPreparation(binding) }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let review = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        let participant = ReviewTeardownParticipant()
        var teardownCount = 0
        participant.onInvalidate = {
            teardownCount += 1
            XCTAssertFalse(review.isActive)
            XCTAssertEqual(fixture.coordinator.phase, .paused)
            outage.value = false
            fixture.store.loadHandler = nil
            fixture.coordinator.retryRecovery()
            XCTAssertEqual(fixture.coordinator.phase, .loading)
        }
        review.register(participant)
        let presentationsBeforeOutage = fixture.events.presentations.count
        outage.value = true
        fixture.store.loadHandler = { _ in .unavailable }
        waits.resume(0)
        await waitForCondition { teardownCount == 1 && fixture.coordinator.phase == .reviewing }

        let replacement = try presentedReview(fixture.coordinator)
        XCTAssertFalse(replacement === review)
        XCTAssertTrue(replacement.isActive)
        let recoveryPresentations = Array(fixture.events.presentations.dropFirst(presentationsBeforeOutage))
        XCTAssertEqual(recoveryPresentations.count, 2)
        guard recoveryPresentations.count == 2,
              case .waiting = recoveryPresentations[0],
              case .approval(let publishedReview) = recoveryPresentations[1] else {
            return XCTFail("Teardown retry must suppress the superseded pause notification")
        }
        XCTAssertTrue(publishedReview === replacement)
    }


    func testRegistrationWaitsForRuntimeAndStartIsIdempotent() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        XCTAssertEqual(fixture.coordinator.phase, .registered)
        XCTAssertEqual(fixture.store.recordCount, 0)
        start(fixture)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.store.recordedOwner, nativeOwner(runtime: fixture.runtime))
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
    }


    func testUnavailableValidationBecomesDormantAndExplicitlyRecovers() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var reads = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            }
        ))
        fixture.store.loadHandler = { _ in reads += 1; return .unavailable }
        start(fixture)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertTrue(fixture.coordinator.isDormant)
        XCTAssertTrue(fixture.coordinator.countsTowardUnverifiedLimit)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        let pausedReads = reads
        let unexpectedRead = expectation(description: "Dormant start must not read the store")
        unexpectedRead.isInverted = true
        unexpectedRead.assertForOverFulfill = false
        fixture.store.onRead = { unexpectedRead.fulfill() }
        start(fixture)
        XCTAssertEqual(fixture.coordinator.phase, .paused)
        await fulfillment(of: [unexpectedRead], timeout: 0.1)
        fixture.store.onRead = nil
        XCTAssertEqual(reads, pausedReads)
        fixture.store.loadHandler = nil
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
    }


    func testReceiptAcquisitionRetryRevalidatesOwnershipBeforeWriting() async throws {
        let fixture = try makeFixture()
        fixture.store.recordHandler = { _, _, _ in .ownershipLost }
        start(fixture)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertTrue(fixture.coordinator.isDormant)
        XCTAssertNil(fixture.coordinator.currentPresentation)

        fixture.store.snapshot = try ownedSnapshot(fixture, runtime: UUID())
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        guard case .superseded? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Retry must observe the replacement receipt before acquiring")
        }
    }


    func testLateValidationCannotAcquireAfterCancellation() async throws {
        let fixture = try makeFixture()
        let gate = TestGate<ExtensionBridge.SnapshotResult>()
        let original = try XCTUnwrap(fixture.store.snapshot)
        let loadStarted = expectation(description: "validation load started")
        var loads = 0
        var rejections = 0
        fixture.store.loadHandler = { _ in
            loads += 1
            if loads == 1 {
                loadStarted.fulfill()
                return await gate.wait()
            }
            return .found(original)
        }
        fixture.store.unownedRejectHandler = { _ in
            rejections += 1
            return .persisted
        }
        start(fixture)
        await fulfillment(of: [loadStarted], timeout: 1)
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .finished)
        let returned = expectation(description: "retired validation returned")
        fixture.store.onLoadReturned = { returned.fulfill() }
        await expectNoFurtherWork(events: fixture.events, store: fixture.store, returned: returned) {
            gate.resolve(.found(original))
        }
        fixture.store.onLoadReturned = nil
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testDelayedValidationCannotExtendRegistrationLifetime() async throws {
        let fixture = try makeFixture()
        let snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.date.addingTimeInterval(ExtensionBridge.requestTTL + 30)
        )
        fixture.store.snapshot = snapshot
        let gate = TestGate<ExtensionBridge.SnapshotResult>()
        let loadStarted = expectation(description: "validation suspended")
        fixture.store.loadHandler = { _ in
            loadStarted.fulfill()
            return await gate.wait()
        }
        start(fixture)
        await fulfillment(of: [loadStarted], timeout: 1)
        fixture.clock.advance(to: fixture.clock.date.addingTimeInterval(ExtensionBridge.requestTTL + 10))
        fixture.store.loadHandler = nil
        gate.resolve(.found(snapshot))
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }


    func testForeignReceiptBeforeStartupNeverAuthenticatesOrPreparesWallets() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("Foreign ownership must not retry") },
            prepare: { _, _ in
                XCTFail("Foreign ownership must not prepare a request")
                return .unavailable
            },
            reloadWallets: {
                XCTFail("Foreign ownership must not reload wallets")
                return false
            }
        ))
        fixture.store.snapshot = try ownedSnapshot(fixture, runtime: UUID())
        start(fixture)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }


    func testLateBootstrapLoadCannotPresentAfterRejection() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        let snapshot = try XCTUnwrap(fixture.store.snapshot)
        let gate = TestGate<ExtensionBridge.SnapshotResult>()
        let loadStarted = expectation(description: "bootstrap load started")
        let loadReturned = expectation(description: "canceled bootstrap load returned")
        var didSuspend = false
        fixture.store.loadHandler = { _ in
            if didSuspend { return .found(snapshot) }
            didSuspend = true
            loadStarted.fulfill()
            let result = await gate.wait()
            loadReturned.fulfill()
            return result
        }
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await fulfillment(of: [loadStarted], timeout: 1)
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        gate.resolve(.found(snapshot))
        await fulfillment(of: [loadReturned], timeout: 1)
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        guard case .waiting = fixture.events.presentations.first,
              case .finished = fixture.events.presentations.last else {
            return XCTFail("A canceled bootstrap must wait for rejection and finish without a review")
        }
    }


    func testCancellationWaitsForInFlightReceiptThenRejectsExactOwner() async throws {
        let fixture = try makeFixture()
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        fixture.store.recordHandler = { _, _, _ in await gate.wait() }
        var rejections = 0
        fixture.store.rejectHandler = { handle, nonce, runtime in
            XCTAssertEqual(handle, fixture.key.handle)
            XCTAssertEqual(nonce, fixture.key.nativeDeliveryNonce)
            XCTAssertEqual(runtime, fixture.runtime)
            rejections += 1
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .acquiringReceipt)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        fixture.coordinator.cancelBeforeAuthentication()
        fixture.coordinator.cancelBeforeAuthentication()
        XCTAssertEqual(fixture.coordinator.phase, .acquiringReceipt)
        XCTAssertEqual(rejections, 0)
        fixture.store.snapshot = try ownedSnapshot(fixture)
        gate.resolve(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }


    func testRecreatedCoordinatorRequiresFreshReviewBeforeClaiming() async throws {
        let fixture = try makeFixture()
        fixture.store.snapshot = try ownedSnapshot(fixture)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testPreauthenticationCancellationFinishesForForeignOrExecutingReceipt() async throws {
        for foreign in [false, true] {
            let fixture = try makeFixture()
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.store.snapshot = try ownedSnapshot(
                fixture,
                runtime: foreign ? UUID() : fixture.runtime,
                phase: foreign ? .queued : .approving
            )
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Must not reject foreign or executing work")
                return .ownershipLost
            }
            fixture.coordinator.cancelBeforeAuthentication()
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(fixture.events.authenticationCount, 1)
        }
    }


    func testAuthenticationWaitingExpiresAndLeavesInbox() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let expiryWaits = ScheduledWaits()
        defer { expiryWaits.resumeAll() }
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("Authentication expiry must not use recovery polling") },
            waitForAuthenticationExpiry: { await expiryWaits.wait(UInt64($0 * 1_000_000_000)) }
        ))
        let deadline = clock.date.addingTimeInterval(10)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: deadline
        )
        let finished = expectation(description: "unauthenticated approval expired")
        var inbox = ApprovalInbox<String>()
        XCTAssertTrue(inbox.register(fixture.coordinator))
        let events = fixture.events
        let key = fixture.key
        fixture.coordinator.onEvent = { event in
            events.record(event, coordinator: fixture.coordinator)
            if case .presentationChanged = event,
               case .finished? = fixture.coordinator.currentPresentation?.presentation {
                inbox.remove(key)
                finished.fulfill()
            }
        }
        defer { fixture.coordinator.onEvent = nil }

        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        await waitForScheduledWait(expiryWaits, count: 1)
        XCTAssertEqual(expiryWaits.delays, [10_000_000_000])
        clock.advance(to: deadline)
        expiryWaits.resume(0)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(inbox.count, 0)
        XCTAssertEqual(events.authenticationCount, 1)
        XCTAssertEqual(events.presentations.count, 1)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        fixture.coordinator.cancelBeforeAuthentication()
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(events.presentations.count, 1)
    }


    func testAuthenticationWaitingDoesNotExpireBeforeRecordedDeadline() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let expiryWaits = ScheduledWaits()
        defer { expiryWaits.resumeAll() }
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("Authentication expiry must not use recovery polling") },
            waitForAuthenticationExpiry: { await expiryWaits.wait(UInt64($0 * 1_000_000_000)) }
        ))
        let deadline = clock.date.addingTimeInterval(10)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: deadline
        )
        start(fixture)
        await waitForScheduledWait(expiryWaits, count: 1)
        clock.advance(to: clock.date.addingTimeInterval(4))
        expiryWaits.resume(0)
        await waitForScheduledWait(expiryWaits, count: 2)
        XCTAssertEqual(fixture.coordinator.phase, .awaitingAuthentication)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
        XCTAssertEqual(expiryWaits.delays, [10_000_000_000, 6_000_000_000])
        clock.advance(to: deadline)
        expiryWaits.resume(1)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }


    func testAuthenticationExpiryDoesNotInterruptCancellationPersistence() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let expiryWaits = ScheduledWaits()
        defer { expiryWaits.resumeAll() }
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("Suspended rejection must not poll") },
            waitForAuthenticationExpiry: { await expiryWaits.wait(UInt64($0 * 1_000_000_000)) }
        ))
        let deadline = clock.date.addingTimeInterval(10)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: deadline
        )
        let writeStarted = expectation(description: "rejection write started")
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        defer { gate.resolve(.persisted) }
        fixture.store.rejectHandler = { _, _, _ in
            writeStarted.fulfill()
            return await gate.wait()
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        await waitForScheduledWait(expiryWaits, count: 1)
        fixture.coordinator.cancelBeforeAuthentication()
        await fulfillment(of: [writeStarted], timeout: 1)

        clock.advance(to: deadline)
        let returned = expectation(description: "retired expiry returned")
        expiryWaits.onReturned = { _ in returned.fulfill() }
        await expectNoFurtherWork(events: fixture.events, store: fixture.store, returned: returned) {
            expiryWaits.resume(0)
        }
        expiryWaits.onReturned = nil
        XCTAssertEqual(fixture.coordinator.phase, .rejecting)
        XCTAssertTrue(fixture.events.presentations.isEmpty)
        XCTAssertEqual(expiryWaits.delays.count, 1)
        gate.resolve(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testSynchronousAuthenticationCallbackReplacesExpiryWorkBeforeItStarts() async throws {
        for authenticates in [false, true] {
            let clock = TestClock(uptimeNanoseconds: 0)
            var preparations = 0
            var expiryWaits = 0
            let unexpectedExpiry = expectation(description: "replaced expiry must not start")
            unexpectedExpiry.isInverted = true
            var completions = 0
            var rejections = 0
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in XCTFail("Immediate completion must not poll") },
                waitForAuthenticationExpiry: { _ in
                    expiryWaits += 1
                    unexpectedExpiry.fulfill()
                    throw CancellationError()
                },
                prepare: { request, _ in
                    preparations += 1
                    XCTAssertTrue(authenticates)
                    return .immediate(.failure(.userRejected))
                }))
            fixture.store.completeHandler = { _, _, _, _ in completions += 1; return .persisted }
            fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
            fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator, events = fixture.events] event in
                guard let coordinator else { return }
                events.record(event, coordinator: coordinator)
                if case .authenticationRequired = event {
                    if authenticates {
                        coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
                        coordinator.cancelBeforeAuthentication()
                    } else {
                        coordinator.cancelBeforeAuthentication()
                        coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
                    }
                }
            }
            defer { fixture.coordinator.onEvent = nil }

            start(fixture)
            await waitForState(fixture.coordinator, .finished)
            await fulfillment(of: [unexpectedExpiry], timeout: 0.1)
            XCTAssertEqual(expiryWaits, 0)
            XCTAssertEqual(preparations, authenticates ? 1 : 0)
            XCTAssertEqual(completions, authenticates ? 1 : 0)
            XCTAssertEqual(rejections, authenticates ? 0 : 1)
            XCTAssertEqual(fixture.store.recordCount, 1)
            XCTAssertEqual(fixture.events.authenticationCount, 1)
            XCTAssertEqual(fixture.events.presentations.count, authenticates ? 2 : 1)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }


    func testOwnedCancellationDeadlineExpiresAuthenticationWaiting() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                if delay <= 1_000_000_000 {
                    clock.advance(to: clock.date.addingTimeInterval(ExtensionBridge.requestTTL))
                } else {
                    try? await TestDeferred<Void>().value()
                }
            },
            prepare: { binding, _ in self.approvalPreparation(binding) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.loadHandler = { _ in .unavailable }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        fixture.store.loadHandler = nil
        fixture.store.snapshot = try ownedSnapshot(fixture)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        XCTAssertEqual(fixture.coordinator.phase, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 1)
    }


    func testPreauthenticationCancellationCannotRejectAfterOwnedReceiptDisappears() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle, nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.date.addingTimeInterval(300)
        )
        fixture.store.unownedRejectHandler = { _ in
            XCTFail("Previously owned cancellation must never fall back to unowned rejection")
            return .persisted
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("The receipt is no longer owned")
            return .persisted
        }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
    }


    func testLostReceiptAfterAuthenticationCannotBeReacquired() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: fixture.clock.date.addingTimeInterval(300)
        )
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 1)
        guard case .superseded = fixture.events.presentations.last else {
            return XCTFail("Expected lost ownership")
        }
    }


    func testRepeatedCatalogRequirementPausesAndReadsCatalogAfterOwnershipRecheck() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var reloads = 0
        var catalogReads = 0
        var needsCatalog = true
        var revalidated = false
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            wait: { _ in try? await TestDeferred<Void>().value() },
            prepare: { binding, catalog in
                guard catalog != nil else { return .needsCatalog }
                return needsCatalog ? .needsCatalog : self.approvalPreparation(binding)
            },
            reloadWallets: {
                reloads += 1
                revalidated = false
                return true
            },
            currentReviewCatalog: {
                XCTAssertTrue(revalidated, "Catalog access must follow the post-reload ownership check")
                catalogReads += 1
                return reviewCatalogForTesting(action: self.accountSelectionAction())
            }
        ))
        fixture.store.onLoadReturned = { revalidated = true }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .paused)
        XCTAssertTrue(fixture.coordinator.requiresExplicitReviewRetry)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(catalogReads, 1)
        needsCatalog = false
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(catalogReads, 2)
        fixture.store.snapshot = nil
    }


    func testReceiptAndWalletRetriesRemainOnTheirOwnSideOfAuthentication() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var reloads = 0
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                if reloads < 2 { await Task.yield() }
                else { try? await TestDeferred<Void>().value() }
            },
            prepare: { binding, catalog in
                guard catalog != nil else { return .needsCatalog }
                preparations += 1
                return self.approvalPreparation(binding)
            },
            reloadWallets: {
                reloads += 1
                return reloads > 1
            },
            currentReviewCatalog: { reviewCatalogForTesting(action: self.accountSelectionAction()) }
        ))
        fixture.store.recordHandler = { _, _, _ in
            fixture.store.recordHandler = nil
            return .retryablePersistenceFailure
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(fixture.store.recordCount, 2)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(preparations, 1)
        fixture.store.snapshot = nil
    }


    func testSuccessfulWalletReloadPastDeadlineLeavesLoadingState() async throws {
        for expiresRequest in [false, true] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in XCTFail("Expired preparation must not retry") },
                prepare: { _, catalog in
                    guard catalog != nil else { return .needsCatalog }
                    XCTFail("Expired preparation must not create a review")
                    return .unavailable
                },
                reloadWallets: {
                    if expiresRequest {
                        clock.advance(to: clock.date.addingTimeInterval(ExtensionBridge.requestTTL))
                    } else {
                        clock.advanceUptime(by: UInt64((NativeApprovalTiming.recoveryTimeout) * 1_000_000_000))
                    }
                    return true
                },
                currentReviewCatalog: {
                    XCTFail("Expired preparation must not read the wallet catalog")
                    return nil
                }
            ))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())

            await waitForState(fixture.coordinator, expiresRequest ? .finished : .paused)
            XCTAssertEqual(fixture.events.presentations.count, 2)
        }
    }


    func testPostauthenticationLoadingStopsAtAdmissionDeadline() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var reloads = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in clock.advance(to: clock.date.addingTimeInterval(301)) },
            prepare: { binding, catalog in
                guard catalog != nil else { return .needsCatalog }
                return requestProcessorForTesting().prepare(binding, catalog: catalog)
            },
            reloadWallets: {
                reloads += 1
                return false
            },
            currentReviewCatalog: { reviewCatalogForTesting(action: self.accountSelectionAction()) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 2)
    }


    func testPostauthenticationUnavailableLoadingStopsAtDeadline() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in clock.advance(to: clock.date.addingTimeInterval(ExtensionBridge.requestTTL)) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.loadHandler = { _ in .unavailable }
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 2)
    }


    func testApprovalInboxDoesNotApplyProfileCapacityGlobally() async throws {
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 2)
        for id in 0..<24 {
            let fixture = try makeFixture(key: approvalKey(id: id, profileIdentifier: UUID()))
            XCTAssertTrue(inbox.register(fixture.coordinator))
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            XCTAssertTrue(inbox.activate("active-\(id)", for: fixture.key))
        }
        XCTAssertEqual(inbox.count, 24)
    }


    func testApprovalInboxOrdersAuthenticationAndBreaksTiesDeterministically() async throws {
        var inbox = ApprovalInbox<String>()
        let newer = try makeFixture(createdAt: 200)
        let higherSequence = try makeFixture(createdAt: 100, sequence: 2)
        let firstTie = try makeFixture(createdAt: 100, sequence: 1)
        let secondTie = try makeFixture(createdAt: 100, sequence: 1)
        let unstarted = try makeFixture()
        let fixtures = [newer, higherSequence, firstTie, secondTie]
        for fixture in fixtures + [unstarted] {
            XCTAssertTrue(inbox.register(fixture.coordinator))
        }
        for fixture in fixtures.reversed() {
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
        }
        XCTAssertEqual(inbox.awaitingAuthenticationKeys, [firstTie.key, secondTie.key, higherSequence.key, newer.key])
        XCTAssertEqual(inbox.coordinators.map(\.handle), (fixtures + [unstarted]).map { $0.key.handle })
        for fixture in fixtures { XCTAssertTrue(inbox.activate("active", for: fixture.key)) }
        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, firstTie.key)
        inbox.remove(firstTie.key)
        XCTAssertEqual(inbox.oldestActive(where: { _ in true })?.key, secondTie.key)
    }


    func testSequentialCancellationsReleaseRegistrationsAndEmitOnce() async throws {
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 1)
        for _ in 0..<8 {
            let fixture = try makeFixture()
            XCTAssertTrue(inbox.register(fixture.coordinator))
            fixture.coordinator.cancelBeforeAuthentication()
            fixture.coordinator.cancelBeforeAuthentication()
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(fixture.events.presentations.count, 1)
            inbox.remove(fixture.key)
        }
        XCTAssertEqual(inbox.count, 0)
    }


    func testReactivationCapabilitiesFollowApprovalLifecycle() async throws {
        let fixture = try makeFixture()
        XCTAssertFalse(fixture.coordinator.canReactivate)
        XCTAssertFalse(fixture.coordinator.hasAuthenticated)
        XCTAssertTrue(fixture.coordinator.countsTowardUnverifiedLimit)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertTrue(fixture.coordinator.isAwaitingAuthentication)
        XCTAssertFalse(fixture.coordinator.canReactivate)
        XCTAssertFalse(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertTrue(fixture.coordinator.canReactivate)
        XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertFalse(fixture.coordinator.canReactivate)
        XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
    }


    func testCoordinatorWithoutLocalAuthorizationInterruptsOwnedExecution() async throws {
        let fixture = try makeFixture()
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.interruptionCount, 1)
        guard case .interrupted? = fixture.events.presentations.last else {
            return XCTFail("Lost authorization must not wait for execution")
        }
        fixture.coordinator.retryRecovery()
        XCTAssertEqual(fixture.store.interruptionCount, 1)
    }


    func testImmediateResponseRetriesWithoutPrematureFailure() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let handle = makeHandle(id: 12)
        let nonce = NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.date.addingTimeInterval(300)
        )
        _ = try XCTUnwrap(snapshot.request)
        let response = ImmediateResolution.failure(.userRejected)
        var completionCount = 0
        var failureCount = 0
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.recordHandler = { _, _, _ in
            snapshot = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.date.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    owner: self.nativeOwner(runtime: runtime)
                )
            )
            return .persisted
        }
        store.completeHandler = { _, _, _, _ in
            completionCount += 1
            return completionCount == 7
                ? .persisted
                : .retryablePersistenceFailure
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            store: store,
            environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in await Task.yield() },
                prepare: { _, _ in .immediate(response) })
        )
        coordinator.onEvent = { [weak coordinator] event in
            if case .presentationChanged = event,
               case .rejecting? = coordinator?.currentPresentation?.presentation { failureCount += 1 }
        }

        guard case .finished = await loadPreparedPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected immediate completion")
        }
        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertGreaterThan(completionCount, 3)
        XCTAssertEqual(failureCount, 0)
    }


    func testLateResponseSettlesBeforeRecoveryCanRetry() async throws {
        for commits in [false, true] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let started = expectation(description: "response in flight")
            let gate = TestGate<ExtensionBridge.StoreMutationResult>()
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in await Task.yield() },
                prepare: { request, _ in
                    .immediate(.failure(.userRejected))
                }))
            var writes = 0
            fixture.store.completeHandler = { _, _, _, _ in
                writes += 1
                started.fulfill()
                return await gate.wait()
            }
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Closing cannot replace an accepted response")
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await fulfillment(of: [started], timeout: 1)
            clock.advance(to: clock.date.addingTimeInterval(11))
            fixture.coordinator.reject()
            fixture.coordinator.retryRecovery()
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(fixture.coordinator.phase, .responding)
            gate.resolve(commits ? .persisted : .retryablePersistenceFailure)
            await waitForState(fixture.coordinator, commits ? .finished : .paused)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }


    func testDelayedResponseKeepsItsIntentAndSerializesPersistence() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let retryWrite = expectation(description: "response retries through a storage outage")
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            },
            prepare: { request, _ in
                .immediate(.failure(.userRejected))
            }))
        var responses = [NSDictionary]()
        fixture.store.completeHandler = { _, _, _, response in
            responses.append(response.response(for: fixture.store.snapshot!.request!)!.json as NSDictionary)
            if responses.count == 7 {
                retryWrite.fulfill()
                return await gate.wait()
            }
            return .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Persisting a response must not start a competing rejection")
            return .ownershipLost
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await fulfillment(of: [retryWrite], timeout: 1)

        XCTAssertEqual(fixture.coordinator.phase, .responding)
        XCTAssertEqual(fixture.events.presentations.count, 1)
        guard case .waiting? = fixture.events.presentations.first else {
            return XCTFail("Response persistence must retain its waiting presentation")
        }
        fixture.coordinator.reject()
        gate.resolve(.persisted)
        await waitForState(fixture.coordinator, .finished)

        XCTAssertGreaterThan(responses.count, 3)
        XCTAssertTrue(responses.allSatisfy { $0 == responses[0] })
        XCTAssertEqual(fixture.events.presentations.count, 2)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testResponseOwnershipLossRepeatedlyPausesWithoutRepreparing() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in XCTFail("Semantic failure must pause") },
            prepare: { request, _ in
                preparations += 1
                return .immediate(.failure(.userRejected))
            }))
        var responses = [NSDictionary]()
        fixture.store.completeHandler = { _, _, _, response in
            responses.append(response.response(for: fixture.store.snapshot!.request!)!.json as NSDictionary)
            return responses.count < 3 ? .ownershipLost : .persisted
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A paused response must retain its accepted intent")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        for attempt in 1...2 {
            await waitForState(fixture.coordinator, .paused)
            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(responses.count, attempt)
            XCTAssertTrue(fixture.coordinator.canReactivate)
            fixture.coordinator.reject()
            XCTAssertTrue(fixture.coordinator.isPaused)
            fixture.coordinator.retryRecovery()
            XCTAssertEqual(fixture.coordinator.phase, .responding)
        }
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(responses.count, 3)
        XCTAssertTrue(responses.allSatisfy { $0 == responses[0] })
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testVisibleLoadingAndResponsePersistenceShareOneRecoveryBudget() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var delays = [UInt64]()
        var reloads = 0
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                delays.append(delay)
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            },
            prepare: { request, catalog in
                guard catalog != nil else { return .needsCatalog }
                preparations += 1
                return .immediate(.failure(.userRejected))
            },
            reloadWallets: { reloads += 1; return reloads == 7 },
            currentReviewCatalog: { reviewCatalogForTesting(action: self.accountSelectionAction()) }
        ))
        var writes = 0
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            return .retryablePersistenceFailure
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .paused)

        XCTAssertEqual((Double(clock.uptimeNanoseconds) / 1_000_000_000), 10)
        XCTAssertEqual(reloads, 7)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(writes, 4)
        XCTAssertEqual(delays, Array(repeating: 1_000_000_000, count: 10))
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        guard case .waiting? = fixture.events.presentations.first,
              case .retryRequired? = fixture.events.presentations.last else {
            return XCTFail("Loading and persistence must retain the same waiting presentation")
        }
    }


    func testApprovalFinalizesImmediatelyAfterFreshReadWithExactAuthorization() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization started without a timer")
        var authorizations = [ReviewConsent]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { authorization in
                authorizations.append(authorization)
                started.fulfill()
                return await finalizer.wait()
            }
        ))
        defer { waits.resumeAll() }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Accepted approval cannot become rejection")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        let approvedAt = clock.date.addingTimeInterval(2)
        clock.advance(to: approvedAt)
        let receipt = NativeDeliveryReceipt(
            nativeDeliveryNonce: fixture.key.nativeDeliveryNonce,
            owner: nativeOwner(runtime: fixture.runtime)
        )
        fixture.store.snapshot = try approvalSnapshot(
            handle: fixture.key.handle, nonce: fixture.key.nativeDeliveryNonce,
            deadline: clock.date.addingTimeInterval(200), receipt: receipt, sequence: 17
        )
        let current = try XCTUnwrap(fixture.store.snapshot)
        var finalizationReads = 0
        fixture.store.loadHandler = { _ in
            finalizationReads += 1
            return .found(current)
        }
        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator, events = fixture.events] event in
            events.record(event, coordinator: coordinator)
            if case .presentationChanged = event,
               case .waiting? = coordinator?.currentPresentation?.presentation {
                XCTAssertEqual(coordinator?.phase, .waiting)
                coordinator?.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
                coordinator?.approveAddEthereumChain(review: nativeReview)
                coordinator?.reject()
            }
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Accepting a decision must synchronously replace review")
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        fixture.coordinator.reject()
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(authorizations.count, 1)
        XCTAssertEqual(finalizationReads, 1)
        XCTAssertEqual(authorizations.first?.nativeReceipt, receipt)
        XCTAssertEqual(authorizations.first?.approvedAt, approvedAt)
        XCTAssertEqual(waits.delays.count, 1)
        XCTAssertTrue(waits.isPending(0))

        var reads = 0
        fixture.store.loadHandler = { _ in reads += 1; return .missing }
        let returned = expectation(description: "retired observation wait returned")
        waits.onReturned = { _ in returned.fulfill() }
        await expectNoFurtherWork(events: fixture.events, store: fixture.store, returned: returned) {
            waits.resume(0)
        }
        waits.onReturned = nil
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(authorizations.count, 1)
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        finalizer.resolve(.responseReady)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 4)
        fixture.store.loadHandler = nil
    }


    func testExpiredApprovalCannotInvokeFinalizationBeforeDispatch() async throws {
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            decisions += 1
            return .responseReady
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        let snapshot = try XCTUnwrap(fixture.store.snapshot)
        let deadline = try XCTUnwrap(snapshot.request?.admissionDeadline)
        var reads = 0
        fixture.store.loadHandler = { _ in reads += 1; return .found(snapshot) }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        fixture.clock.advance(to: deadline)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testPendingFinalizationObservesWithBackoffWithoutReplayingDecision() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization started")
        var decisions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in
                decisions += 1
                started.fulfill()
                return await finalizer.wait()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await fulfillment(of: [started], timeout: 1)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        finalizer.resolve(.pending)
        await waitForScheduledWait(waits, count: 2)
        XCTAssertEqual(decisions, 1)
        for index in 1...3 {
            if index == 3 {
                fixture.store.snapshot = try ownedSnapshot(fixture, phase: .responded)
            }
            clock.advance(to: clock.date.addingTimeInterval(Double(waits.delays[index]) / 1_000_000_000))
            waits.resume(index)
            if index < 3 { await waitForScheduledWait(waits, count: index + 2) }
        }
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(Array(waits.delays.dropFirst()), [1_000_000_000, 2_000_000_000, 4_000_000_000])
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testUnavailableReviewPreparationRequiresExplicitRetry() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let available = LockedTestValue(false)
        var preparations = 0
        var completions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in
                preparations += 1
                return available.value ? self.approvalPreparation(binding) : .unavailable
            }))
        defer { waits.resumeAll() }
        fixture.store.completeHandler = { _, _, _, _ in completions += 1; return .persisted }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .paused)
        XCTAssertTrue(fixture.coordinator.requiresExplicitReviewRetry)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(completions, 0)

        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(completions, 0)

        available.value = true
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(preparations, 3)
        XCTAssertEqual(completions, 0)
    }


    func testTemporaryResolutionFailureRequiresExplicitRetryAndNewConsent() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        var preparations = 0
        var consents = [ReviewConsent]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in
                preparations += 1
                return self.approvalPreparation(binding)
            },
            attemptNativeDecision: { consent in
                consents.append(consent)
                if consents.count == 1 {
                    consent.invalidateAuthorization()
                    return .reviewRequired
                }
                return .responseReady
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await waitForState(fixture.coordinator, .paused)

        XCTAssertTrue(fixture.coordinator.requiresExplicitReviewRetry)
        XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(consents.count, 1)
        XCTAssertFalse(consents[0].authorizationIsAvailable)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        guard case .retryRequired? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Temporary resolution failure must offer a fresh review")
        }
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        XCTAssertEqual(consents.count, 1)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        let replacementReview = try presentedReview(fixture.coordinator)
        XCTAssertFalse(replacementReview === nativeReview)
        XCTAssertFalse(fixture.coordinator.requiresExplicitReviewRetry)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(consents.count, 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        fixture.coordinator.reject(review: nativeReview)
        XCTAssertEqual(fixture.coordinator.phase, .reviewing)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: replacementReview)
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(consents.count, 2)
        XCTAssertFalse(consents[0].sharesAuthorization(with: consents[1]))
        XCTAssertEqual(consents[0].binding, consents[1].binding)
        XCTAssertEqual(consents[0].nativeReceipt, consents[1].nativeReceipt)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testTemporaryResolutionRetryCannotExtendOriginalAdmissionDeadline() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        var decisions = 0
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in
                preparations += 1
                return self.approvalPreparation(binding)
            },
            attemptNativeDecision: { consent in
                decisions += 1
                consent.invalidateAuthorization()
                return .reviewRequired
            }
        ))
        defer { waits.resumeAll() }
        let deadline = try XCTUnwrap(fixture.store.snapshot?.request?.admissionDeadline)
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await waitForState(fixture.coordinator, .paused)
        clock.advance(to: deadline)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testReviewRetryReturnedAfterAdmissionDeadlineFinishesWithoutPausing() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, attemptNativeDecision: { consent in
            consent.invalidateAuthorization()
            clock.advance(to: consent.request.admissionDeadline)
            return .reviewRequired
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertFalse(fixture.coordinator.requiresExplicitReviewRetry)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        XCTAssertFalse(fixture.events.presentations.contains {
            if case .retryRequired = $0 { return true }
            return false
        })
    }


    func testPendingExecutionReturningToQueueInterruptsWithoutReplayingDecision() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization started")
        var decisions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in
                decisions += 1
                started.fulfill()
                return await finalizer.wait()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await fulfillment(of: [started], timeout: 1)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        finalizer.resolve(.pending)
        await waitForScheduledWait(waits, count: 2)
        waits.resume(1)
        await waitForScheduledWait(waits, count: 3)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .queued)
        waits.resume(2)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(fixture.store.interruptionCount, 1)
        guard case .interrupted? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("An abandoned execution requires a fresh review")
        }
        fixture.coordinator.retryRecovery()
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        XCTAssertEqual(decisions, 1)
    }


    func testInterruptionPersistenceRetriesWithoutReplayingApproval() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        var decisions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) }, wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in decisions += 1; return .interruptionRequired }
        ))
        defer { waits.resumeAll() }
        var interruptions = 0
        fixture.store.interruptionHandler = {
            interruptions += 1
            return interruptions < 3 ? .retryablePersistenceFailure : .interrupted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await waitForScheduledWait(waits, count: 2)
        XCTAssertEqual(fixture.coordinator.phase, .rejecting)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        fixture.coordinator.retryRecovery()
        fixture.coordinator.reject()
        waits.resume(1)
        await waitForScheduledWait(waits, count: 3)
        waits.resume(2)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(interruptions, 3)
        guard case .interrupted? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Expected terminal interruption")
        }
        fixture.coordinator.retryRecovery()
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        XCTAssertEqual(decisions, 1)
        XCTAssertFalse(fixture.coordinator.canReactivate)
    }


    func testApprovalLoadOwnershipChangeDoesNotInvokeFinalization() async throws {
        var decisions = 0
        let fixture = try makeFixture(attemptNativeDecision: { _ in
            decisions += 1
            return .responseReady
        })
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        fixture.store.snapshot = try ownedSnapshot(fixture, runtime: UUID())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(fixture.store.interruptionCount, 0)
    }


    func testSuspendedApprovalLoadDoesNotRetainCoordinatorOrFinalizeAfterRelease() async throws {
        let load = TestGate<ExtensionBridge.SnapshotResult>()
        let started = expectation(description: "approval load suspended")
        var decisions = 0
        var fixture: Fixture? = try makeFixture(attemptNativeDecision: { _ in
            decisions += 1
            return .responseReady
        })
        weak let coordinator = fixture?.coordinator
        let events = try XCTUnwrap(fixture?.events)
        let store = try XCTUnwrap(fixture?.store)
        start(try XCTUnwrap(fixture))
        await waitForState(try XCTUnwrap(coordinator), .awaitingAuthentication)
        coordinator?.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(try XCTUnwrap(coordinator), .reviewing)
        let nativeReview = try presentedReview(try XCTUnwrap(coordinator))
        let snapshot = try XCTUnwrap(store.snapshot)
        store.loadHandler = { _ in started.fulfill(); return await load.wait() }
        coordinator?.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await fulfillment(of: [started], timeout: 1)
        let presentations = events.presentations.count
        fixture = nil
        XCTAssertNil(coordinator)
        let returned = expectation(description: "released coordinator load returned")
        store.onLoadReturned = { returned.fulfill() }
        await expectNoFurtherWork(events: events, store: store, returned: returned) {
            load.resolve(.found(snapshot))
        }
        store.onLoadReturned = nil
        XCTAssertEqual(decisions, 0)
        XCTAssertEqual(events.presentations.count, presentations)
        XCTAssertEqual(store.interruptionCount, 0)
    }


    func testAcceptedResponseIgnoresCloseBetweenRetries() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waiting = expectation(description: "retry suspended")
        let gate = TestGate<Void>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in waiting.fulfill(); await gate.wait() },
            prepare: { request, _ in
                .immediate(.failure(.userRejected))
            }))
        var responses = 0
        fixture.store.completeHandler = { _, _, _, _ in
            responses += 1
            return responses == 1 ? .retryablePersistenceFailure : .persisted
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A response retry must retain its intent")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await fulfillment(of: [waiting], timeout: 1)
        fixture.coordinator.reject()
        gate.resolve(())
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(responses, 2)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testAmbiguousResponseCommitWinsOverCancellation() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let writeStarted = expectation(description: "response write in flight")
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in await Task.yield() },
            prepare: { request, _ in
                .immediate(.failure(.userRejected))
            }))
        fixture.store.completeHandler = { _, _, _, _ in
            writeStarted.fulfill()
            return await gate.wait()
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("A durably committed response must win over cancellation")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await fulfillment(of: [writeStarted], timeout: 1)
        fixture.coordinator.reject()
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .responded)
        gate.resolve(.retryablePersistenceFailure)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testRetriedRejectionCannotOverlapAnotherClose() async throws {
        let fixture = try makeFixture()
        let started = expectation(description: "retried rejection in flight")
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        var writes = 0
        fixture.store.rejectHandler = { _, _, _ in
            writes += 1
            if writes == 1 {
                fixture.clock.advance(to: fixture.clock.date.addingTimeInterval(11))
                return .retryablePersistenceFailure
            }
            started.fulfill()
            return await gate.wait()
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .paused)
        fixture.coordinator.retryRecovery()
        await fulfillment(of: [started], timeout: 1)
        fixture.coordinator.reject()
        fixture.coordinator.retryRecovery()
        XCTAssertEqual(writes, 2)
        gate.resolve(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testResponseReconciliationStopsWhenReceiptOwnershipChanges() async throws {
        for result in [ExtensionBridge.StoreMutationResult.ownershipLost,
                       .retryablePersistenceFailure] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in XCTFail("Foreign ownership must not retry") },
                prepare: { request, _ in
                    .immediate(.failure(.userRejected))
                }))
            let foreign = try ownedSnapshot(fixture, runtime: UUID())
            fixture.store.completeHandler = { _, _, _, _ in
                fixture.store.snapshot = foreign
                return result
            }
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Foreign ownership must not be rejected")
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(fixture.events.presentations.count, 2)
            guard case .superseded? = fixture.events.presentations.last else {
                return XCTFail("Ownership replacement must supersede local processing")
            }
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }


    func testResponseRecoveryUsesTenSecondBudgetAndFixedCadence() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let started = clock.date
        var delays = [UInt64]()
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                delays.append(delay)
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            },
            prepare: { request, _ in
                .immediate(.failure(.userRejected))
            }))
        var writes = 0
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            return .retryablePersistenceFailure
        }
        fixture.store.rejectHandler = { _, _, _ in
            XCTFail("Recovery timeout is not rejection")
            return .persisted
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(clock.date.timeIntervalSince(started), 10)
        XCTAssertEqual(delays, Array(repeating: 1_000_000_000, count: 10))
        XCTAssertEqual(writes, 10)
        let unexpectedWrite = expectation(description: "Paused recovery must not write the store")
        unexpectedWrite.isInverted = true
        unexpectedWrite.assertForOverFulfill = false
        fixture.store.onWrite = { unexpectedWrite.fulfill() }
        await fulfillment(of: [unexpectedWrite], timeout: 0.1)
        fixture.store.onWrite = nil
        XCTAssertEqual(fixture.coordinator.phase, .paused)
        XCTAssertEqual(writes, 10)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testLateResponseReconciliationRecognizesDurableWork() async throws {
        for phase in [RequestPhase.approving, .responded] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in try? await TestDeferred<Void>().value() },
                prepare: { request, _ in
                    .immediate(.failure(.userRejected))
                }))
            let committed = try ownedSnapshot(fixture, phase: phase)
            fixture.store.completeHandler = { _, _, _, _ in
                clock.advance(to: clock.date.addingTimeInterval(11))
                fixture.store.snapshot = committed
                return .retryablePersistenceFailure
            }
            fixture.store.rejectHandler = { _, _, _ in
                XCTFail("Late committed work must not be rejected")
                return .persisted
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await waitForState(fixture.coordinator, .finished)
            XCTAssertFalse(fixture.coordinator.isPaused)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
            fixture.store.snapshot = nil
        }
    }


    func testRejectionUsesExactReceiptOwner() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let handle = makeHandle(id: 6)
        let nonce = NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        let snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.date.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                owner: self.nativeOwner(runtime: runtime)
            )
        )
        let rejected = expectation(description: "rejected")
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.rejectHandler = { _, value, owner in
            XCTAssertEqual(value, nonce)
            XCTAssertEqual(owner, runtime)
            rejected.fulfill()
            return .persisted
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            store: store,
            environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in await Task.yield() },
                prepare: { binding, _ in
                    self.approvalPreparation(binding)
                })
        )
        guard case .approval = await loadPreparedPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected approval")
        }

        coordinator.reject()
        await fulfillment(of: [rejected], timeout: 1)

        XCTAssertEqual(coordinator.phase, .finished)
    }


    func testRejectionStopsAfterReceiptOwnershipChanges() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let handle = makeHandle(id: 14)
        let nonce = NativeDeliveryNonce(value: UUID())
        let runtime = UUID()
        var snapshot = try approvalSnapshot(
            handle: handle,
            nonce: nonce,
            deadline: clock.date.addingTimeInterval(300),
            receipt: .init(
                nativeDeliveryNonce: nonce,
                owner: self.nativeOwner(runtime: runtime)
            )
        )
        var rejectionCount = 0
        let finished = expectation(description: "foreign receipt reconciled")
        let store = CoordinatorStore()
        store.loadHandler = { _ in .found(snapshot) }
        store.rejectHandler = { _, _, _ in
            rejectionCount += 1
            snapshot = try! self.approvalSnapshot(
                handle: handle,
                nonce: nonce,
                deadline: clock.date.addingTimeInterval(300),
                receipt: .init(
                    nativeDeliveryNonce: nonce,
                    owner: self.nativeOwner(runtime: UUID())
                )
            )
            return .ownershipLost
        }
        let coordinator = NativeApprovalCoordinator(
            handle: handle,
            nativeDeliveryNonce: nonce,
            store: store,
            environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in
                    try? await TestDeferred<Void>().value()
                },
                prepare: { binding, _ in
                    self.approvalPreparation(binding)
                })
        )
        coordinator.onEvent = { [weak coordinator] event in
            if case .presentationChanged = event,
               case .superseded? = coordinator?.currentPresentation?.presentation { finished.fulfill() }
        }
        guard case .approval = await loadPreparedPresentation(coordinator, runtime: runtime) else {
            return XCTFail("Expected approval")
        }

        coordinator.reject()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(rejectionCount, 1)
        XCTAssertEqual(coordinator.phase, .finished)
    }


    func testBackwardWallClockCannotExtendRecoveryBudget() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let started = (Double(clock.uptimeNanoseconds) / 1_000_000_000)
        var writes = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                clock.advanceUptime(by: UInt64((Double(delay) / 1_000_000_000) * 1_000_000_000))
                clock.setDate(clock.date.addingTimeInterval(-60))
                await Task.yield()
            },
            prepare: { request, _ in
                .immediate(.failure(.userRejected))
            }))
        fixture.store.completeHandler = { _, _, _, _ in
            writes += 1
            return .retryablePersistenceFailure
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual((Double(clock.uptimeNanoseconds) / 1_000_000_000) - started, 10)
        XCTAssertEqual(writes, 10)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testCanceledObservationWaitCannotPollTheNewApprovalState() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let started = expectation(description: "finalization started")
        var finalizations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in
                finalizations += 1
                started.fulfill()
                return await finalizer.wait()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        let store = fixture.store
        clock.advance(to: clock.date.addingTimeInterval(2))
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await waitForState(fixture.coordinator, .waiting)
        await fulfillment(of: [started], timeout: 1)
        store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        finalizer.resolve(.pending)
        await waitForScheduledWait(waits, count: 2)
        var loads = 0
        store.loadHandler = { _ in
            loads += 1
            return store.snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }

        let returned = expectation(description: "retired observation wait returned")
        waits.onReturned = { _ in returned.fulfill() }
        await expectNoFurtherWork(events: fixture.events, store: fixture.store, returned: returned) {
            waits.resume(0)
        }
        waits.onReturned = nil
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(fixture.events.presentations.count, 3)

        store.snapshot = nil
        waits.resume(1)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(finalizations, 1)
    }


    func testSuspendedObservationDoesNotBlockRetriesOrApplyStaleMetadata() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let probe = TestGate<ExtensionBridge.SnapshotResult>()
        let probeStarted = expectation(description: "observation load suspended")
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let finalizerStarted = expectation(description: "finalization started")
        var finalizations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in
                finalizations += 1
                finalizerStarted.fulfill()
                return await finalizer.wait()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        let originalOrder = fixture.coordinator.order
        let store = fixture.store
        var loads = 0
        store.loadHandler = { _ in
            loads += 1
            if loads == 1 {
                probeStarted.fulfill()
                return await probe.wait()
            }
            return store.snapshot.map(ExtensionBridge.SnapshotResult.found) ?? .missing
        }
        waits.resume(0)
        await fulfillment(of: [probeStarted], timeout: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await fulfillment(of: [finalizerStarted], timeout: 1)
        store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        finalizer.resolve(.pending)
        await waitForScheduledWait(waits, count: 2)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(waits.delays.count, 2)
        waits.resume(1)
        await waitForState(fixture.coordinator, .waiting)
        await waitForScheduledWait(waits, count: 3)
        let stale = try approvalSnapshot(
            handle: fixture.key.handle,
            nonce: fixture.key.nativeDeliveryNonce,
            deadline: clock.date.addingTimeInterval(-1),
            host: "stale.example"
        )

        let readsBeforeOldObservationReturns = loads
        let returned = expectation(description: "superseded observation returned")
        store.onLoadReturned = { returned.fulfill() }
        await expectNoFurtherWork(events: fixture.events, store: store, returned: returned) {
            probe.resolve(.found(stale))
        }
        store.onLoadReturned = nil
        XCTAssertEqual(fixture.coordinator.peer?.title, "wallet.example")
        XCTAssertEqual(fixture.coordinator.order, originalOrder)
        XCTAssertEqual(fixture.coordinator.phase, .waiting)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(loads, readsBeforeOldObservationReturns)
        XCTAssertEqual(store.maximumOutstandingWrites, 1)
        XCTAssertEqual(fixture.events.presentations.count, 3)

        store.snapshot = nil
        waits.resume(2)
        await waitForState(fixture.coordinator, .finished)
    }


    func testPendingFinalizerAtDeadlineFinishesWithoutAnotherObservation() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let finalizer = TestGate<NativeApprovalFinalizationResult>()
        let finalizerStarted = expectation(description: "finalizer suspended")
        var finalizations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: waits.wait,
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in
                finalizations += 1
                finalizerStarted.fulfill()
                return await finalizer.wait()
            }
        ))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        await waitForScheduledWait(waits, count: 1)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        await fulfillment(of: [finalizerStarted], timeout: 1)
        clock.advance(to: clock.date.addingTimeInterval(301))
        finalizer.resolve(.pending)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(finalizations, 1)
        XCTAssertEqual(waits.delays.count, 1)
        XCTAssertEqual(fixture.events.presentations.count, 4)
        guard case .waiting = fixture.events.presentations[2],
              case .finished = fixture.events.presentations[3] else {
            return XCTFail("The observed decision must enter waiting and finish at expiry")
        }
    }


    func testSuspendedTasksDoNotRetainCoordinator() async throws {
        for suspendLoad in [true, false] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let waits = ScheduledWaits()
            let load = TestGate<ExtensionBridge.SnapshotResult>()
            var fixture: Fixture? = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
                uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: waits.wait,
                prepare: { binding, _ in self.approvalPreparation(binding) }
            ))
            weak let coordinator = fixture?.coordinator
            let events = try XCTUnwrap(fixture?.events)
            var retainedReview: NativeApprovalReview?
            let participant = ReviewTeardownParticipant()
            var teardownCount = 0
            participant.onInvalidate = { teardownCount += 1 }
            if suspendLoad {
                let loadStarted = expectation(description: "validation load suspended")
                fixture?.store.loadHandler = { _ in
                    loadStarted.fulfill()
                    return await load.wait()
                }
                start(try XCTUnwrap(fixture))
                await fulfillment(of: [loadStarted], timeout: 1)
            } else {
                start(try XCTUnwrap(fixture))
                await waitForState(try XCTUnwrap(coordinator), .awaitingAuthentication)
                coordinator?.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
                await waitForState(try XCTUnwrap(coordinator), .reviewing)
                retainedReview = try presentedReview(try XCTUnwrap(coordinator))
                retainedReview?.register(participant)
                await waitForScheduledWait(waits, count: 1)
            }
            let presentationCount = events.presentations.count
            let store = try XCTUnwrap(fixture?.store)
            let returned = expectation(description: "released coordinator dependency returned")
            if suspendLoad { store.onLoadReturned = { returned.fulfill() } }
            else { waits.onReturned = { _ in returned.fulfill() } }
            fixture = nil
            XCTAssertNil(coordinator)
            if let retainedReview {
                XCTAssertFalse(retainedReview.isActive)
                XCTAssertEqual(teardownCount, 1)
            }
            await expectNoFurtherWork(events: events, store: store, returned: returned) {
                if suspendLoad { load.resolve(.missing) }
                waits.resumeAll()
            }
            XCTAssertEqual(events.presentations.count, presentationCount)
        }
    }


    func testSuspendedFinalizerDoesNotRetainCoordinatorOrPresentAfterRelease() async throws {
        for result in [NativeApprovalFinalizationResult.responseReady, .interruptionRequired] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let finalizer = TestGate<NativeApprovalFinalizationResult>()
            let started = expectation(description: "finalizer suspended")
            let returned = expectation(description: "released finalizer returned")
            var fixture: Fixture? = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in await Task.yield() },
                prepare: { binding, _ in self.approvalPreparation(binding) },
                attemptNativeDecision: { _ in
                    started.fulfill()
                    let value = await finalizer.wait()
                    returned.fulfill()
                    return value
                }
            ))
            weak let coordinator = fixture?.coordinator
            let events = try XCTUnwrap(fixture?.events)
            start(try XCTUnwrap(fixture))
            await waitForState(try XCTUnwrap(coordinator), .awaitingAuthentication)
            coordinator?.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await waitForState(try XCTUnwrap(coordinator), .reviewing)
            let nativeReview = try presentedReview(try XCTUnwrap(coordinator))
            coordinator?.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
            await fulfillment(of: [started], timeout: 1)
            let count = events.presentations.count
            let store = try XCTUnwrap(fixture?.store)
            fixture = nil
            XCTAssertNil(coordinator)
            await expectNoFurtherWork(events: events, store: store, returned: returned) {
                finalizer.resolve(result)
            }
            XCTAssertEqual(events.presentations.count, count)
        }
    }


    func testRuntimeArrivalDuringCancellationCannotCauseUnownedRejection() async throws {
        let fixture = try makeFixture()
        let snapshot = try ownedSnapshot(fixture)
        let gate = TestGate<ExtensionBridge.SnapshotResult>()
        let started = expectation(description: "pre-runtime cancellation read")
        fixture.store.loadHandler = { _ in started.fulfill(); return await gate.wait() }
        fixture.store.unownedRejectHandler = { _ in
            XCTFail("Missing captured runtime must not downgrade an owned mutation")
            return .persisted
        }
        fixture.coordinator.cancelBeforeAuthentication()
        await fulfillment(of: [started], timeout: 1)
        start(fixture)
        gate.resolve(.found(snapshot))
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 0)
        fixture.store.loadHandler = nil
    }


    func testDormantCancellationPreservesRejectionOnForegroundRecovery() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            }
        ))
        fixture.store.loadHandler = { _ in .unavailable }
        fixture.coordinator.cancelBeforeAuthentication()
        await waitForState(fixture.coordinator, .paused)
        fixture.store.loadHandler = nil
        start(fixture)
        XCTAssertTrue(fixture.coordinator.isDormant)
        XCTAssertEqual(fixture.store.recordCount, 0)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.store.recordCount, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
    }


    func testDormantEntriesExpireWithoutBlockingInboxCapacity() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            }
        ))
        var inbox = ApprovalInbox<String>(maximumUnverifiedCount: 1)
        XCTAssertTrue(inbox.register(fixture.coordinator))
        fixture.store.loadHandler = { _ in .unavailable }
        start(fixture)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(inbox.dormantCoordinators.count, 1)
        clock.advance(to: clock.date.addingTimeInterval(ExtensionBridge.requestTTL))
        XCTAssertTrue(fixture.coordinator.isExpiredDormant)
        let replacement = try makeFixture(clock: clock)
        XCTAssertTrue(inbox.register(replacement.coordinator))
        XCTAssertEqual(inbox.count, 1)
        XCTAssertNil(inbox.coordinator(for: fixture.key))
    }


    func testFreshReviewAfterRetryFencesTheNextApproval() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let available = LockedTestValue(false)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                if available.value { try? await TestDeferred<Void>().value() }
                else {
                    clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                    await Task.yield()
                }
            },
            prepare: { binding, catalog in
                guard catalog != nil else { return .needsCatalog }
                return self.approvalPreparation(binding)
            },
            reloadWallets: { available.value },
            currentReviewCatalog: { reviewCatalogForTesting(action: self.accountSelectionAction()) }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .paused)
        let pausedRevision = try XCTUnwrap(fixture.coordinator.currentPresentation?.revision)
        available.value = true
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        let reviewRevision = try XCTUnwrap(fixture.coordinator.currentPresentation?.revision)
        XCTAssertGreaterThan(reviewRevision, pausedRevision)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        guard case .waiting? = fixture.events.presentations.last else {
            return XCTFail("Approval after a recovered review must immediately fence its UI")
        }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.coordinator.currentPresentation?.revision), reviewRevision)
        await waitForState(fixture.coordinator, .waiting)
        let waitingCount = fixture.events.presentations.filter {
            if case .waiting = $0 { return true }
            return false
        }.count
        XCTAssertEqual(waitingCount, 3)
        fixture.store.snapshot = nil
    }


    func testObservationOutagePausesAfterTenSecondsAndRetriesFreshPreparation() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let waits = ScheduledWaits()
        let unavailable = LockedTestValue(false)
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                if unavailable.value {
                    clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                    await Task.yield()
                } else { await waits.wait(delay) }
            },
            prepare: { binding, _ in
                preparations += 1
                return self.approvalPreparation(binding)
            }))
        defer { waits.resumeAll() }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        await waitForScheduledWait(waits, count: 1)
        var reads = 0
        unavailable.value = true
        fixture.store.loadHandler = { _ in reads += 1; return .unavailable }
        waits.resume(0)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual((Double(clock.uptimeNanoseconds) / 1_000_000_000), 10)
        let pausedReads = reads
        let unexpectedRead = expectation(description: "Paused observation must not read the store")
        unexpectedRead.isInverted = true
        unexpectedRead.assertForOverFulfill = false
        fixture.store.onRead = { unexpectedRead.fulfill() }
        await fulfillment(of: [unexpectedRead], timeout: 0.1)
        fixture.store.onRead = nil
        XCTAssertEqual(fixture.coordinator.phase, .paused)
        XCTAssertEqual(reads, pausedReads)
        unavailable.value = false
        fixture.store.loadHandler = nil
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(fixture.store.recordCount, 1)
        fixture.store.rejectHandler = { _, _, _ in .persisted }
        fixture.coordinator.reject()
        await waitForState(fixture.coordinator, .finished)
    }


    func testObservedExecutionWithoutLocalDecisionCannotExecute() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        var executions = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in await Task.yield() },
            prepare: { binding, _ in self.approvalPreparation(binding) },
            attemptNativeDecision: { _ in executions += 1; return .responseReady }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        fixture.store.snapshot = try ownedSnapshot(fixture, phase: .approving)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(fixture.store.interruptionCount, 1)
    }


    func testPresentationSnapshotIsPublishedBeforeNotificationAndDeduplicatesWaiting() async throws {
        let fixture = try makeFixture()
        XCTAssertNil(fixture.coordinator.currentPresentation)
        var snapshots = [NativeApprovalCoordinator.PresentationSnapshot]()
        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator] event in
            guard case .presentationChanged = event else { return }
            guard let snapshot = coordinator?.currentPresentation else {
                return XCTFail("Snapshot must be available before notification")
            }
            XCTAssertGreaterThan(snapshot.revision, snapshots.last?.revision ?? 0)
            snapshots.append(snapshot)
        }
        defer { fixture.coordinator.onEvent = nil }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        XCTAssertNil(fixture.coordinator.currentPresentation)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Loading must synchronously publish waiting")
        }
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Accepting the review must synchronously publish waiting")
        }
        await waitForState(fixture.coordinator, .waiting)
        XCTAssertEqual(snapshots.count, 3)
        guard case .waiting = snapshots[0].presentation,
              case .approval = snapshots[1].presentation,
              case .waiting = snapshots[2].presentation else {
            return XCTFail("Expected initial loading, review, and accepted approval waiting")
        }
    }


    func testReentrantReviewDecisionCannotStartTheReplacedObserver() async throws {
        for approves in [false, true] {
            let clock = TestClock(uptimeNanoseconds: 0)
            var observationWaits = 0
            let unexpectedObservation = expectation(description: "replaced observation must not start")
            unexpectedObservation.isInverted = true
            var decisions = 0
            var rejections = 0
            var reviews = 0
            let fixture = try makeFixture(clock: clock, environment: .init(
                now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
                wait: { _ in observationWaits += 1; unexpectedObservation.fulfill() },
                prepare: { binding, _ in self.approvalPreparation(binding) },
                attemptNativeDecision: { _ in decisions += 1; return .responseReady }
            ))
            fixture.store.rejectHandler = { _, _, _ in rejections += 1; return .persisted }
            fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator] event in
                guard case .presentationChanged = event, let coordinator,
                      case .approval(let nativeReview)? = coordinator.currentPresentation?.presentation else { return }
                XCTAssertEqual(coordinator.phase, .reviewing)
                let reviewRevision = coordinator.currentPresentation?.revision ?? 0
                reviews += 1
                if approves {
                    coordinator.approveAccounts([], ethereumNetwork: nil, review: nativeReview)
                } else {
                    coordinator.reject(review: nativeReview)
                }
                XCTAssertEqual(coordinator.phase, approves ? .waiting : .rejecting)
                XCTAssertGreaterThan(coordinator.currentPresentation?.revision ?? 0, reviewRevision)
                guard case .waiting? = coordinator.currentPresentation?.presentation else {
                    return XCTFail("The reentrant decision must synchronously replace the review")
                }
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
            await waitForState(fixture.coordinator, .finished)
            await fulfillment(of: [unexpectedObservation], timeout: 0.1)

            XCTAssertEqual(reviews, 1)
            XCTAssertEqual(decisions, approves ? 1 : 0)
            XCTAssertEqual(rejections, approves ? 0 : 1)
            XCTAssertEqual(observationWaits, 0)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
            XCTAssertTrue(fixture.coordinator.hasAuthenticated)
        }
    }


    func testRecoveryAndTerminalNotificationsAllowSynchronousReentry() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let available = LockedTestValue(false)
        var waits = 0
        var preparations = 0
        var completions = 0
        var recoveries = 0
        var finishes = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { delay in
                waits += 1
                clock.advance(to: clock.date.addingTimeInterval(Double(delay) / 1_000_000_000))
                await Task.yield()
            },
            prepare: { request, catalog in
                guard catalog != nil else { return .needsCatalog }
                preparations += 1
                return .immediate(.failure(.userRejected))
            },
            reloadWallets: { available.value },
            currentReviewCatalog: { reviewCatalogForTesting(action: self.accountSelectionAction()) }
        ))
        fixture.store.completeHandler = { _, _, _, _ in completions += 1; return .persisted }
        let runtime = nativeOwner(runtime: fixture.runtime)
        fixture.coordinator.onEvent = { [weak coordinator = fixture.coordinator, events = fixture.events] event in
            guard let coordinator else { return }
            events.record(event, coordinator: coordinator)
            guard case .presentationChanged = event,
                  let snapshot = coordinator.currentPresentation else { return }
            switch snapshot.presentation {
            case .retryRequired:
                recoveries += 1
                available.value = true
                coordinator.retryRecovery()
                XCTAssertEqual(coordinator.phase, .loading)
                guard case .waiting? = coordinator.currentPresentation?.presentation else {
                    return XCTFail("Nested retry must publish its new waiting state synchronously")
                }
            case .finished:
                finishes += 1
                coordinator.start(nativeDeliveryOwner: runtime)
                coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
                coordinator.retryRecovery()
                coordinator.reject()
                XCTAssertEqual(coordinator.phase, .finished)
                XCTAssertEqual(coordinator.currentPresentation?.revision, snapshot.revision)
            default:
                break
            }
        }
        defer { fixture.coordinator.onEvent = nil }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .finished)

        XCTAssertEqual(waits, 10)
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 4)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testRepeatedCloseDoesNotRestartPausedRejection() async throws {
        for authenticates in [false, true] {
            let clock = TestClock(uptimeNanoseconds: 0)
            let fixture = try makeFixture(clock: clock)
            let key = fixture.key
            let runtime = fixture.runtime
            var rejections = 0
            fixture.store.rejectHandler = { handle, nonce, owner in
                XCTAssertEqual(handle, key.handle)
                XCTAssertEqual(nonce, key.nativeDeliveryNonce)
                XCTAssertEqual(owner, runtime)
                rejections += 1
                if rejections == 1 {
                    clock.advance(to: clock.date.addingTimeInterval(11))
                    return .retryablePersistenceFailure
                }
                return .persisted
            }
            fixture.store.unownedRejectHandler = { _ in
                XCTFail("Cancellation must retain its acquired receipt")
                return .ownershipLost
            }
            start(fixture)
            await waitForState(fixture.coordinator, .awaitingAuthentication)
            if authenticates {
                fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
                await waitForState(fixture.coordinator, .reviewing)
            }
            fixture.coordinator.reject()
            await waitForState(fixture.coordinator, .paused)
            XCTAssertEqual(fixture.coordinator.hasAuthenticated, authenticates)
            XCTAssertEqual(fixture.coordinator.isDormant, !authenticates)
            XCTAssertFalse(fixture.coordinator.countsTowardUnverifiedLimit)
            if !authenticates { XCTAssertNil(fixture.coordinator.currentPresentation) }
            fixture.coordinator.reject()
            XCTAssertEqual(rejections, 1)
            XCTAssertTrue(fixture.coordinator.isPaused)
            fixture.coordinator.retryRecovery()
            XCTAssertEqual(fixture.coordinator.phase, .rejecting)
            XCTAssertFalse(fixture.coordinator.canReactivate)
            await waitForState(fixture.coordinator, .finished)
            XCTAssertEqual(rejections, 2)
            XCTAssertEqual(fixture.store.recordCount, 1)
            XCTAssertEqual(fixture.events.authenticationCount, 1)
            XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
        }
    }


    func testFailureRejectionRetryUsesOrdinaryWaitingPresentation() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let account = WalletAccount(
            address: "0x0000000000000000000000000000000000000001",
            coin: .ethereum, derivation: .custom,
            derivationPath: "m/44'/60'/0'/0/7", publicKey: "", extendedPublicKey: ""
        )
        let network = ResolvedEthereumNetwork(network: EthereumNetwork(
            chainId: 1, name: "Ethereum", symbol: "ETH",
            rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
            isTestnet: false, mightShowPrice: true, explorer: nil
        ), source: .custom)
        let transaction = Transaction(from: account.address, to: account.address, value: "0x0", data: "0x")
        var preparations = 0
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID, uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in await Task.yield() },
            prepare: { binding, _ in
                preparations += 1
                return self.approvalPreparation(binding, action: .approveTransaction(SendTransactionAction(
                    transaction: transaction, resolvedNetwork: network, walletId: "wallet", account: account
                )))
            },
            attemptNativeDecision: { _ in
                XCTFail("An invalid transaction decision must be rejected without execution")
                return .responseReady
            }
        ), requestAction: .approveTransaction(SendTransactionAction(
            transaction: transaction, resolvedNetwork: network, walletId: "wallet", account: account
        )))
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        let retryStarted = expectation(description: "retried failure rejection")
        defer { gate.resolve(.persisted) }
        var rejections = 0
        fixture.store.rejectHandler = { _, _, _ in
            rejections += 1
            if rejections == 1 {
                clock.advance(to: clock.date.addingTimeInterval(11))
                return .retryablePersistenceFailure
            }
            retryStarted.fulfill()
            return await gate.wait()
        }
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        let nativeReview = try presentedReview(fixture.coordinator)
        fixture.coordinator.approveTransaction(transaction, reviewedNetwork: network, review: nativeReview, authorization: NativeApprovalTestAuthorization.grant(nativeReview.makeTransactionAuthenticationChallenge(transaction: transaction, reviewedNetwork: network)))
        guard case .rejecting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Invalid approval must initially show the rejection surface")
        }
        await waitForState(fixture.coordinator, .paused)
        fixture.coordinator.retryRecovery()
        await fulfillment(of: [retryStarted], timeout: 1)
        XCTAssertEqual(fixture.coordinator.phase, .rejecting)
        guard case .waiting? = fixture.coordinator.currentPresentation?.presentation else {
            return XCTFail("Explicit rejection retry must use the ordinary waiting surface")
        }
        let revision = fixture.coordinator.currentPresentation?.revision
        fixture.coordinator.reject()
        fixture.coordinator.retryRecovery()
        XCTAssertEqual(fixture.coordinator.currentPresentation?.revision, revision)
        XCTAssertEqual(rejections, 2)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
        gate.resolve(.persisted)
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(fixture.events.presentations.count, 6)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testCanceledReceiptAcquisitionRemainsCanceledAfterRecoveryPauses() async throws {
        let fixture = try makeFixture()
        let gate = TestGate<ExtensionBridge.StoreMutationResult>()
        let started = expectation(description: "receipt acquisition in flight")
        fixture.store.recordHandler = { _, _, _ in started.fulfill(); return await gate.wait() }
        var rejections = 0
        fixture.store.unownedRejectHandler = { _ in rejections += 1; return .persisted }
        start(fixture)
        await fulfillment(of: [started], timeout: 1)
        fixture.coordinator.cancelBeforeAuthentication()
        fixture.clock.advance(to: fixture.clock.date.addingTimeInterval(11))
        fixture.store.recordHandler = nil
        gate.resolve(.retryablePersistenceFailure)
        await waitForState(fixture.coordinator, .paused)
        XCTAssertEqual(rejections, 0)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        fixture.coordinator.retryRecovery()
        await waitForState(fixture.coordinator, .finished)
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.authenticationCount, 0)
        XCTAssertEqual(fixture.store.maximumOutstandingWrites, 1)
    }


    func testWalletIndependentBootstrapSkipsReloadAndDoesNotReacquireReceipt() async throws {
        let clock = TestClock(uptimeNanoseconds: 0)
        let fixture = try makeFixture(clock: clock, environment: .init(
            now: { clock.date }, authorityID: NativeApprovalTestAuthorization.authorityID,
            uptime: { (Double(clock.uptimeNanoseconds) / 1_000_000_000) },
            wait: { _ in try? await TestDeferred<Void>().value() },
            prepare: { binding, catalog in
                XCTAssertNil(catalog)
                return self.approvalPreparation(binding)
            },
            reloadWallets: {
                XCTFail("Wallet-independent preparation must not reload wallets")
                return false
            },
            currentReviewCatalog: {
                XCTFail("Wallet-independent preparation must not access wallets")
                return nil
            }
        ))
        start(fixture)
        await waitForState(fixture.coordinator, .awaitingAuthentication)
        fixture.coordinator.resumeAfterAuthentication(authorization: NativeApprovalTestAuthorization.accessSession())
        await waitForState(fixture.coordinator, .reviewing)
        XCTAssertEqual(fixture.store.recordCount, 1)
        XCTAssertEqual(fixture.events.presentations.count, 2)
        fixture.store.snapshot = nil
    }

}

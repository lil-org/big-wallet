import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class AccountPreviewStateTests: XCTestCase {
    func testSelectionPreservesUndiscoveredAccountsAndOutputOrder() async throws {
        let original = wallet(accounts: [account(8), account(0), account(9)])
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: original, sessions: sessions, changes: changes)
        state.reset()

        XCTAssertTrue(state.hasEnabledAccounts)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, original.accounts)
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }

        XCTAssertEqual(state.enabledAccounts, [account(0), account(8), account(9)])
        state.toggle(at: 1)
        state.toggle(at: 0)
        XCTAssertTrue(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(9)])
        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        state.loadMore()
        await finish(next, with: [account(8), account(2)])
        await expectEventually { changes.insertions.count == 1 }

        XCTAssertEqual(changes.insertions, [2..<4])
        XCTAssertTrue(state.isEnabled(account(8)))
        XCTAssertFalse(state.isEnabled(account(2)))
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(9)])
        state.toggle(at: 0)
        state.toggle(at: 1)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(8), account(9)])
    }

    func testDisablingAndRestoringTheLastSelection() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }

        state.toggle(at: 0)
        XCTAssertFalse(state.hasEnabledAccounts)
        XCTAssertTrue(state.hasChanges)
        XCTAssertTrue(state.enabledAccounts.isEmpty)
        state.toggle(at: 0)
        XCTAssertTrue(state.hasEnabledAccounts)
        XCTAssertFalse(state.hasChanges)
    }

    func testPagingWaitsForLayoutAndCoalescesViewportRequests() async throws {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        state.loadMore()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.generations.count == 1 }
        state.loadMore()
        XCTAssertEqual(sessions.additionalCalls, 0)

        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        state.loadMore()
        state.loadMore()
        await fulfillment(of: [next.entered], timeout: 2)
        state.loadMore()
        XCTAssertEqual(sessions.additionalCalls, 1)
        next.resolve([account(1), account(2)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(changes.insertions, [1..<3])
    }

    func testResetRejectsLateFirstPageWithoutClearingTheReplacementLoad() async throws {
        let first = PreviewRequest()
        let replacement = PreviewRequest()
        let sessions = PreviewSessions(initial: [first, replacement])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await fulfillment(of: [first.entered], timeout: 2)
        state.reset()
        await fulfillment(of: [replacement.entered, first.cancelled], timeout: 2)

        first.resolve([account(7)])
        await fulfillment(of: [first.returned], timeout: 2)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertTrue(changes.generations.isEmpty)
        replacement.resolve([account(0)])
        await expectEventually { changes.generations.count == 1 }
        XCTAssertEqual(state.accounts, [account(0)])
        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        XCTAssertEqual(sessions.initialCalls, 2)
    }

    func testResetRejectsLateAdditionalPageAndOldLayoutActivation() async throws {
        let initial = PreviewRequest()
        let obsolete = PreviewRequest()
        let replacement = PreviewRequest()
        let current = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, replacement], additional: [obsolete, current])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.generations.count == 1 }
        let oldGeneration = try XCTUnwrap(changes.generations.last)
        XCTAssertTrue(state.activatePaging(for: oldGeneration))
        state.loadMore()
        await fulfillment(of: [obsolete.entered], timeout: 2)

        state.reset()
        XCTAssertFalse(state.activatePaging(for: oldGeneration))
        await finish(replacement, with: [account(3)])
        await expectEventually { changes.generations.count == 2 }
        let currentGeneration = try XCTUnwrap(changes.generations.last)
        XCTAssertNotEqual(oldGeneration, currentGeneration)
        XCTAssertTrue(state.activatePaging(for: currentGeneration))
        state.loadMore()
        await fulfillment(of: [current.entered, obsolete.cancelled], timeout: 2)
        obsolete.resolve([account(7)])
        await fulfillment(of: [obsolete.returned], timeout: 2)
        state.loadMore()
        XCTAssertEqual(sessions.additionalCalls, 2)
        XCTAssertEqual(state.accounts, [account(3)])
        current.resolve([account(4)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.accounts, [account(3), account(4)])
        XCTAssertEqual(changes.insertions, [1..<2])
    }

    func testInvalidationCancelsWorkAndSilencesLateResults() async throws {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.generations.count == 1 }
        let generation = try XCTUnwrap(changes.generations.last)
        XCTAssertTrue(state.activatePaging(for: generation))
        state.loadMore()
        await fulfillment(of: [next.entered], timeout: 2)
        let previousChanges = changes.values

        state.invalidate()
        await fulfillment(of: [next.cancelled], timeout: 2)
        XCTAssertFalse(state.activatePaging(for: generation))
        state.loadMore()
        state.toggle(at: 0)
        next.resolve([account(1)])
        await fulfillment(of: [next.returned], timeout: 2)
        XCTAssertEqual(state.accounts, [account(0)])
        XCTAssertEqual(state.enabledAccounts, [account(0)])
        XCTAssertEqual(changes.values, previousChanges)
        XCTAssertEqual(sessions.additionalCalls, 1)
    }

    func testFailuresPreserveSelectionAndAllowLaterPageRetryWithoutEmptyInsertions() async throws {
        let failedInitial = PreviewRequest()
        let initial = PreviewRequest()
        let failedPage = PreviewRequest()
        let successfulPage = PreviewRequest()
        let emptyPage = PreviewRequest()
        let sessions = PreviewSessions(
            initial: [failedInitial, initial], additional: [failedPage, successfulPage, emptyPage]
        )
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(8)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(failedInitial, with: nil)
        state.loadMore()
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertTrue(state.hasEnabledAccounts)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(8)])
        XCTAssertTrue(changes.generations.isEmpty)
        XCTAssertEqual(sessions.additionalCalls, 0)

        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        state.toggle(at: 1)
        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        state.loadMore()
        await finish(failedPage, with: nil)
        await expectEventually {
            state.loadMore()
            return sessions.additionalCalls == 2
        }
        XCTAssertEqual(state.enabledAccounts, [account(0), account(1), account(8)])
        await finish(successfulPage, with: [account(8)])
        await expectEventually { changes.insertions.count == 1 }
        state.loadMore()
        await finish(emptyPage, with: [])
        XCTAssertEqual(changes.insertions, [2..<3])
        XCTAssertEqual(state.accounts, [account(0), account(1), account(8)])
        XCTAssertTrue(state.hasChanges)
    }

    func testRefreshKeepsMetadataChangesAndPristinePreviewPages() async throws {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let original = wallet(accounts: [account(0)])
        let state = makeState(wallet: original, sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        let generation = try XCTUnwrap(changes.generations.last)
        state.toggle(at: 1)
        let refreshedAccount = account(0, publicKey: "refreshed")
        let refreshed = wallet(accounts: [refreshedAccount])

        XCTAssertEqual(state.refresh(wallet: refreshed), .keepEditing)
        XCTAssertEqual(state.wallet.accounts, [refreshedAccount])
        XCTAssertTrue(state.hasChanges)
        XCTAssertTrue(state.isEnabled(account(1)))
        XCTAssertEqual(sessions.initialCalls, 1)
        XCTAssertTrue(state.activatePaging(for: generation))
        state.toggle(at: 1)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(0), account(2)])), .keepEditing)
        XCTAssertTrue(state.activatePaging(for: generation))
        XCTAssertEqual(state.accounts, [account(0), account(1)])
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(2)])
        XCTAssertEqual(sessions.initialCalls, 1)
    }

    func testRefreshRebasesDraftAndOffPageSelectionsWithoutRestartingPendingPagination() async throws {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let last = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next, last])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(8), account(9)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1), account(2)])
        await expectEventually { changes.generations.count == 1 }
        let generation = try XCTUnwrap(changes.generations.last)
        state.toggle(at: 0)
        state.toggle(at: 1)
        XCTAssertTrue(state.activatePaging(for: generation))
        state.loadMore()
        await fulfillment(of: [next.entered], timeout: 2)

        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(0), account(8), account(7)])), .keepEditing)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(7)])
        XCTAssertTrue(state.hasChanges)
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(sessions.initialCalls, 1)
        next.resolve([account(8), account(7), account(3)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(7)])
        XCTAssertTrue(state.activatePaging(for: generation))
        state.loadMore()
        await finish(last, with: [account(4)])
        await expectEventually { changes.insertions.count == 2 }
        XCTAssertEqual(sessions.requestedPages, [1, 2])
        XCTAssertEqual(changes.generations, [generation])
    }

    func testExternallyFulfilledEditsBecomeCleanAndLaterChangesFollowTheNewBaseline() async throws {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(8)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        state.toggle(at: 0)
        state.toggle(at: 1)

        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(1), account(8)])), .keepEditing)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8)])
        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(0), account(8)])), .keepEditing)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(8)])
        XCTAssertEqual(sessions.initialCalls, 1)
    }

    func testRefreshCanLeaveAnEmptyDraftForTheUserToRepair() async throws {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(1)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        state.toggle(at: 0)

        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(0)])), .keepEditing)
        XCTAssertFalse(state.hasEnabledAccounts)
        XCTAssertTrue(state.hasChanges)
        state.toggle(at: 1)
        XCTAssertEqual(state.enabledAccounts, [account(1)])
    }

    func testRefreshRestartsPendingFirstPageAndIgnoresItsLateResult() async throws {
        let obsolete = PreviewRequest()
        let replacement = PreviewRequest()
        let sessions = PreviewSessions(initial: [obsolete, replacement])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await fulfillment(of: [obsolete.entered], timeout: 2)

        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(1), account(8)])), .keepEditing)
        await fulfillment(of: [obsolete.cancelled, replacement.entered], timeout: 2)
        obsolete.resolve([account(0)])
        await fulfillment(of: [obsolete.returned], timeout: 2)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8)])
        replacement.resolve([account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8)])
        XCTAssertFalse(state.hasChanges)
    }

    func testRefreshRetriesFailedInitialPreparationWithTheLatestWallet() async {
        let failed = PreviewRequest()
        let replacement = PreviewRequest()
        let sessions = PreviewSessions(initial: [failed, replacement])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(failed, with: nil)

        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(1)])), .keepEditing)
        await finish(replacement, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        XCTAssertEqual(state.enabledAccounts, [account(1)])
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(sessions.initialCalls, 2)
    }

    func testRefreshClosesOnlyRemovedOrDifferentWallets() async throws {
        for replacement in [nil, WalletSnapshot(id: "other", isMnemonic: true, accounts: [account(2)])] {
            let initial = PreviewRequest()
            let sessions = PreviewSessions(initial: [initial])
            defer { sessions.finishPendingRequests() }
            let changes = PreviewChanges()
            let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
            state.reset()
            await finish(initial, with: [account(0), account(1)])
            await expectEventually { changes.generations.count == 1 }
            let generation = try XCTUnwrap(changes.generations.last)
            state.toggle(at: 1)
            let previousChanges = changes.values

            XCTAssertEqual(state.refresh(wallet: replacement), .close)
            XCTAssertFalse(state.activatePaging(for: generation))
            XCTAssertEqual(changes.values, previousChanges)
            XCTAssertEqual(sessions.initialCalls, 1)
        }
    }

    func testLoadingDoesNotRetainStateAndDeinitializationCancelsTheRequest() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        var state: AccountPreviewState? = makeState(
            wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes
        )
        weak let weakState = state
        state?.reset()
        await fulfillment(of: [initial.entered], timeout: 2)

        state = nil
        XCTAssertNil(weakState)
        await fulfillment(of: [initial.cancelled], timeout: 2)
        initial.resolve([account(0)])
        await fulfillment(of: [initial.returned], timeout: 2)
        XCTAssertEqual(changes.values, [.reload])
    }

    func testReloadCallbackCanInvalidateBeforeTheLoadStarts() {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        weak var observedState: AccountPreviewState?
        let state = AccountPreviewState(
            wallet: wallet(accounts: [account(0)]), makeSession: { _ in await sessions.makeSession() },
            didChange: { _ in observedState?.invalidate() }
        )
        observedState = state
        state.reset()
        XCTAssertEqual(sessions.initialCalls, 0)
    }

    func testRefreshDiscardsLateSessionCreationWithoutStartingItsFirstPage() async throws {
        let obsoletePage = PreviewRequest()
        let replacementPage = PreviewRequest()
        let sessions = PreviewSessions(initial: [obsoletePage, replacementPage])
        defer { sessions.finishPendingRequests() }
        let obsolete = sessions.makeSession()
        let creation = TestGate<any AccountPreviewSession>()
        let entered = expectation(description: "Session creation started")
        let cancelled = expectation(description: "Session creation cancelled")
        let returned = expectation(description: "Session creation returned")
        let calls = Mutex(0)
        let creationAccounts = Mutex([[WalletAccount]]())
        let changes = PreviewChanges()
        let state = AccountPreviewState(wallet: wallet(accounts: [account(0)]), makeSession: { wallet in
            creationAccounts.withLock { $0.append(wallet.accounts) }
            let first = calls.withLock { count in defer { count += 1 }; return count == 0 }
            guard first else { return await sessions.makeSession() }
            return await withTaskCancellationHandler {
                entered.fulfill()
                let session = await creation.wait()
                returned.fulfill()
                return session
            } onCancel: { cancelled.fulfill() }
        }, didChange: changes.receive)
        defer { creation.resolve(obsolete) }
        state.reset()
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(2)])), .keepEditing)
        await fulfillment(of: [cancelled, replacementPage.entered], timeout: 2)
        creation.resolve(obsolete)
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertTrue(changes.generations.isEmpty)
        replacementPage.resolve([account(2)])
        await expectEventually { state.accounts == [self.account(2)] }
        XCTAssertEqual(obsoletePage.calls, 0)
        XCTAssertEqual(changes.generations.count, 1)
        XCTAssertEqual(creationAccounts.withLock { $0 }, [[account(0)], [account(2)]])
        XCTAssertEqual(state.enabledAccounts, [account(2)])
        XCTAssertFalse(state.hasChanges)
    }

    func testDeinitializationCancelsSessionCreation() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        let session = sessions.makeSession()
        let creation = TestGate<any AccountPreviewSession>()
        let entered = expectation(description: "Session creation started")
        let cancelled = expectation(description: "Session creation cancelled")
        let returned = expectation(description: "Session creation returned")
        let changes = PreviewChanges()
        var state: AccountPreviewState? = AccountPreviewState(wallet: wallet(accounts: [account(0)]), makeSession: { _ in
            await withTaskCancellationHandler {
                entered.fulfill()
                let session = await creation.wait()
                returned.fulfill()
                return session
            } onCancel: { cancelled.fulfill() }
        }, didChange: changes.receive)
        weak let observed = state
        state?.reset()
        await fulfillment(of: [entered], timeout: 2)
        state = nil
        XCTAssertNil(observed)
        await fulfillment(of: [cancelled], timeout: 2)
        creation.resolve(session)
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(initial.calls, 0)
        XCTAssertEqual(changes.values, [.reload])
    }

    func testThrottleUsesSuccessfulCompletionAndRemainingDelay() async throws {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let last = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next, last])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let clock = TestClock()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions,
            changes: changes, timing: timing(clock))
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.generations.count == 1 }
        XCTAssertTrue(clock.registrations.isEmpty)
        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        clock.advance(by: 100_000_000)
        state.loadMore()
        await expectEventually { clock.pendingSleeps.count == 1 }
        XCTAssertEqual(clock.pendingSleeps.first?.durationNanoseconds, 130_000_000)
        clock.advance(by: 129_000_000)
        XCTAssertEqual(sessions.additionalCalls, 0)
        clock.advance(by: 1_000_000)
        await fulfillment(of: [next.entered], timeout: 2)
        clock.advance(by: 1_000_000_000)
        next.resolve([account(1)])
        await expectEventually { changes.insertions.count == 1 }
        state.loadMore()
        await expectEventually { clock.pendingSleeps.count == 1 }
        XCTAssertEqual(clock.pendingSleeps.first?.durationNanoseconds, 230_000_000)
        state.invalidate()
        await expectEventually { clock.activeSleepCount == 0 }
        clock.advance(by: 230_000_000)
        XCTAssertEqual(sessions.additionalCalls, 1)
        XCTAssertEqual(state.accounts, [account(0), account(1)])
    }

    func testElapsedThrottleAndExhaustionDoNotScheduleExtraWork() async throws {
        let initial = PreviewRequest()
        let failed = PreviewRequest()
        let empty = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [failed, empty])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let clock = TestClock()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions,
            changes: changes, timing: timing(clock))
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.generations.count == 1 }
        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        clock.advance(by: 230_000_000)
        state.loadMore()
        await finish(failed, with: nil)
        await expectEventually { state.loadMore(); return sessions.additionalCalls == 2 }
        XCTAssertEqual(sessions.requestedPages, [1, 1])
        XCTAssertTrue(clock.registrations.isEmpty)
        await finish(empty, with: [])
        await expectEventually { state.activatePaging(for: changes.generations[0]) }
        let extraPage = expectation(description: "Exhausted session does not derive another page")
        extraPage.isInverted = true
        sessions.onAdditionalRequest = { extraPage.fulfill() }
        clock.advance(by: 1_000_000_000)
        state.loadMore()
        state.loadMore()
        await fulfillment(of: [extraPage], timeout: 0.05)
        XCTAssertEqual(sessions.additionalCalls, 2)
        XCTAssertTrue(changes.insertions.isEmpty)
        XCTAssertEqual(state.enabledAccounts, [account(0)])
    }

    private func timing(_ clock: TestClock) -> AccountPreviewState.Timing {
        let anchor = clock.instant
        let uptime = clock.uptimeNanoseconds
        return .init(now: { clock.instant }, sleepUntil: { deadline in
            let duration = anchor.duration(to: deadline).components
            let nanoseconds = UInt64(duration.seconds) * 1_000_000_000 + UInt64(duration.attoseconds / 1_000_000_000)
            try await clock.sleep(until: uptime + nanoseconds)
        })
    }

    private func makeState(
        wallet: WalletSnapshot,
        sessions: PreviewSessions,
        changes: PreviewChanges,
        timing: AccountPreviewState.Timing = .init(now: { .now }, sleepUntil: { _ in try Task.checkCancellation() })
    ) -> AccountPreviewState {
        AccountPreviewState(wallet: wallet, makeSession: { _ in await sessions.makeSession() }, timing: timing, didChange: changes.receive)
    }

    private func finish(_ request: PreviewRequest, with accounts: [WalletAccount]?) async {
        await fulfillment(of: [request.entered], timeout: 2)
        request.resolve(accounts)
        await fulfillment(of: [request.returned], timeout: 2)
    }

    private func wallet(accounts: [WalletAccount]) -> WalletSnapshot {
        WalletSnapshot(id: "wallet", isMnemonic: true, accounts: accounts)
    }

    private func account(_ index: Int, publicKey: String = "") -> WalletAccount {
        WalletAccount(
            address: "0x" + String(repeating: "0", count: 39) + String(index), coin: .ethereum,
            derivation: .custom, derivationPath: "m/44'/60'/0'/0/\(index)",
            publicKey: publicKey, extendedPublicKey: ""
        )
    }
}

@MainActor
private final class PreviewChanges {
    private(set) var values = [AccountPreviewState.Change]()

    var generations: [UInt64] {
        values.compactMap { if case .initialPage(let generation) = $0 { generation } else { nil } }
    }

    var insertions: [Range<Int>] {
        values.compactMap { if case .append(let range) = $0 { range } else { nil } }
    }

    func receive(_ change: AccountPreviewState.Change) {
        values.append(change)
    }
}

@MainActor
private final class PreviewSessions {
    enum Failure: Error { case unavailable }

    let initial: [PreviewRequest]
    let additional: [PreviewRequest]
    private(set) var initialCalls = 0
    private(set) var additionalCalls = 0
    private(set) var requestedPages = [Int]()
    var onAdditionalRequest: (() -> Void)?

    init(initial: [PreviewRequest], additional: [PreviewRequest] = []) {
        self.initial = initial
        self.additional = additional
    }

    func makeSession() -> any AccountPreviewSession {
        let index = initialCalls
        initialCalls += 1
        return PreviewSession(source: self, initial: initial.indices.contains(index) ? initial[index] : nil)
    }

    func additionalRequest(page: Int) -> PreviewRequest? {
        onAdditionalRequest?()
        requestedPages.append(page)
        let index = additionalCalls
        additionalCalls += 1
        return additional.indices.contains(index) ? additional[index] : nil
    }

    func finishPendingRequests() {
        (initial + additional).forEach { $0.resolve(nil) }
    }
}

@MainActor
private final class PreviewSession: AccountPreviewSession {
    let source: PreviewSessions
    let initial: PreviewRequest?

    init(source: PreviewSessions, initial: PreviewRequest?) {
        self.source = source
        self.initial = initial
    }

    func previewAccounts(page: Int) async throws -> [WalletAccount] {
        let requested = if page == 0 { initial } else { await source.additionalRequest(page: page) }
        guard let request = requested else {
            XCTFail("Unexpected preview page \(page)")
            throw PreviewSessions.Failure.unavailable
        }
        guard let accounts = await request.run() else { throw PreviewSessions.Failure.unavailable }
        return accounts
    }
}

private final class PreviewRequest: Sendable {
    let entered = XCTestExpectation(description: "Preview requested")
    let returned = XCTestExpectation(description: "Preview returned")
    let cancelled = XCTestExpectation(description: "Preview cancelled")
    private let result = TestGate<[WalletAccount]?>()
    private let callCount = Mutex(0)
    var calls: Int { callCount.withLock { $0 } }

    func run() async -> [WalletAccount]? {
        callCount.withLock { $0 += 1 }
        return await withTaskCancellationHandler {
            entered.fulfill()
            let accounts = await result.wait()
            returned.fulfill()
            return accounts
        } onCancel: {
            self.cancelled.fulfill()
        }
    }

    func resolve(_ accounts: [WalletAccount]?) {
        result.resolve(accounts)
    }
}

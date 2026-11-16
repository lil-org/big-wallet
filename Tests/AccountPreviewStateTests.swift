import WalletDomain
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
        await expectEventually { changes.initialPages == 1 }

        XCTAssertEqual(state.enabledAccounts, [account(0), account(8), account(9)])
        state.toggle(at: 1)
        state.toggle(at: 0)
        XCTAssertTrue(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(9)])
        state.requestPaging { true }
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
        await expectEventually { changes.initialPages == 1 }

        state.toggle(at: 0)
        XCTAssertFalse(state.hasEnabledAccounts)
        XCTAssertTrue(state.hasChanges)
        XCTAssertTrue(state.enabledAccounts.isEmpty)
        state.toggle(at: 0)
        XCTAssertTrue(state.hasEnabledAccounts)
        XCTAssertFalse(state.hasChanges)
    }

    func testSaveKeepsItsCapturedDraftAndSurvivesOwnStoreNotification() async {
        let original = wallet(accounts: [account(0)])
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: original, sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        state.toggle(at: 1)
        let selected = state.enabledAccounts
        let saveStarted = expectation(description: "Save started")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        var savedWallet: WalletSnapshot?
        var savedAccounts = [WalletAccount]()
        var wasCancelled = false

        XCTAssertTrue(state.save { wallet, accounts in
            savedWallet = wallet
            savedAccounts = accounts
            saveStarted.fulfill()
            await release.wait()
            wasCancelled = Task.isCancelled
        })
        XCTAssertTrue(state.isSaving)
        XCTAssertFalse(state.canEdit)
        XCTAssertFalse(state.canSave)
        XCTAssertFalse(state.save { _, _ in XCTFail("A second save must not start") })
        state.toggle(at: 0)
        XCTAssertEqual(state.enabledAccounts, selected)
        await fulfillment(of: [saveStarted], timeout: 2)

        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: selected))

        XCTAssertTrue(state.isSaving)
        XCTAssertFalse(state.hasChanges)
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertEqual(savedWallet?.accounts, original.accounts)
        XCTAssertEqual(savedAccounts, selected)
        release.resolve(())
        await expectEventually { changes.values.contains(.close) }
        XCTAssertFalse(wasCancelled)
        XCTAssertFalse(state.isSaving)
        XCTAssertFalse(state.canSave)
        XCTAssertTrue(sessions.created[0].isInvalidated)
    }

    func testSaveFailurePreservesDraftAndAllowsAnotherSave() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        state.toggle(at: 1)
        let selected = state.enabledAccounts

        XCTAssertTrue(state.save { _, _ in throw PreviewSessions.Failure.unavailable })

        await expectEventually { changes.values.contains(.saveFailed) }
        XCTAssertFalse(state.isSaving)
        XCTAssertTrue(state.canSave)
        XCTAssertEqual(state.enabledAccounts, selected)
        XCTAssertTrue(state.hasChanges)
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertTrue(state.save { _, accounts in XCTAssertEqual(accounts, selected) })
        await expectEventually { changes.values.contains(.close) }
    }

    func testUnchangedSaveClosesWithoutMutatingAndEmptySelectionCannotSave() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { state.canEdit }
        state.toggle(at: 0)
        XCTAssertFalse(state.canSave)
        XCTAssertFalse(state.save { _, _ in XCTFail("An empty selection must not be saved") })
        state.toggle(at: 0)

        XCTAssertTrue(state.save { _, _ in XCTFail("An unchanged selection must not be saved") })

        XCTAssertEqual(changes.values.filter { $0 == .close }.count, 1)
        XCTAssertFalse(state.canEdit)
        XCTAssertTrue(sessions.created[0].isInvalidated)
    }

    func testInvalidationSilencesLateSaveSuccessAndFailure() async {
        for fails in [false, true] {
            let initial = PreviewRequest()
            let sessions = PreviewSessions(initial: [initial])
            defer { sessions.finishPendingRequests() }
            let changes = PreviewChanges()
            let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
            state.reset()
            await finish(initial, with: [account(0), account(1)])
            await expectEventually { state.canEdit }
            state.toggle(at: 1)
            let started = expectation(description: "Save started")
            let returned = expectation(description: "Save returned")
            let release = TestGate<Void>()
            defer { release.resolve(()) }
            XCTAssertTrue(state.save { _, _ in
                started.fulfill()
                await release.wait()
                defer { returned.fulfill() }
                XCTAssertTrue(Task.isCancelled)
                if fails { throw PreviewSessions.Failure.unavailable }
            })
            await fulfillment(of: [started], timeout: 2)

            state.invalidate()
            let previousChanges = changes.values
            release.resolve(())
            await fulfillment(of: [returned], timeout: 2)
            await Task.yield()

            XCTAssertEqual(changes.values, previousChanges)
            XCTAssertFalse(state.isSaving)
            XCTAssertFalse(state.canSave)
            XCTAssertFalse(state.canRetry)
        }
    }

    func testCancelledSaveCannotCompleteAReplacementSave() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        state.toggle(at: 1)
        let firstStarted = expectation(description: "First save started")
        let firstReturned = expectation(description: "First save returned")
        let secondStarted = expectation(description: "Second save started")
        let first = TestGate<Void>()
        let second = TestGate<Void>()
        defer { first.resolve(()); second.resolve(()) }
        state.save { _, _ in
            firstStarted.fulfill()
            await first.wait()
            XCTAssertTrue(Task.isCancelled)
            firstReturned.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        state.cancelSave()
        XCTAssertTrue(state.canSave)
        XCTAssertTrue(state.save { _, _ in
            secondStarted.fulfill()
            await second.wait()
            XCTAssertFalse(Task.isCancelled)
        })
        await fulfillment(of: [secondStarted], timeout: 2)
        first.resolve(())
        await fulfillment(of: [firstReturned], timeout: 2)
        await Task.yield()

        XCTAssertTrue(state.isSaving)
        XCTAssertFalse(changes.values.contains(.close))
        second.resolve(())
        await expectEventually { changes.values.contains(.close) }
        XCTAssertEqual(changes.values.filter { $0 == .close }.count, 1)
    }

    func testStoreRetryCoalescesAndRecoversWithoutLosingDraft() async {
        let original = wallet(accounts: [account(0)])
        let initial = PreviewRequest()
        let recovered = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, recovered])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: original, sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        state.toggle(at: 1)
        let selected = state.enabledAccounts
        state.reconcileStore(loadState: .failed(.unavailable), isReady: false, wallet: nil)
        XCTAssertEqual(state.loadPresentation, .failed)
        XCTAssertTrue(state.canRetry)
        let started = expectation(description: "Store reload started")
        let release = TestGate<Void>()
        defer { release.resolve(()) }

        XCTAssertTrue(state.retry { [weak state] in
            started.fulfill()
            await release.wait()
            state?.reconcileStore(loadState: .ready, isReady: true, wallet: original)
        })
        XCTAssertFalse(state.canRetry)
        XCTAssertFalse(state.retry { XCTFail("A second store reload must not start") })
        XCTAssertFalse(state.save { _, _ in XCTFail("An unavailable store must not be saved") })
        await fulfillment(of: [started], timeout: 2)
        release.resolve(())
        await finish(recovered, with: [account(0), account(1)])

        await expectEventually { state.canSave }
        XCTAssertEqual(state.enabledAccounts, selected)
        XCTAssertEqual(state.loadPresentation, .hidden)
        XCTAssertFalse(state.canRetry)
        XCTAssertFalse(changes.values.contains(.close))
    }

    func testInvalidationSuppressesLateStoreReloadAndItsNotification() async {
        let original = wallet(accounts: [account(0)])
        let sessions = PreviewSessions(initial: [])
        let changes = PreviewChanges()
        let state = makeState(wallet: original, sessions: sessions, changes: changes)
        state.reconcileStore(loadState: .failed(.unavailable), isReady: false, wallet: nil)
        let started = expectation(description: "Store reload started")
        let returned = expectation(description: "Store reload returned")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        XCTAssertTrue(state.retry { [weak state] in
            started.fulfill()
            await release.wait()
            XCTAssertTrue(Task.isCancelled)
            state?.reconcileStore(loadState: .ready, isReady: true, wallet: original)
            returned.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)

        state.invalidate()
        let previousChanges = changes.values
        release.resolve(())
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()

        XCTAssertEqual(changes.values, previousChanges)
        XCTAssertEqual(sessions.initialCalls, 0)
        XCTAssertEqual(state.loadPresentation, .hidden)
        XCTAssertFalse(state.canRetry)
    }

    func testPagingWaitsForLayoutAndCoalescesViewportRequests() async throws {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let layout = TestGate<Void>()
        let waitingForLayout = expectation(description: "Paging waits for layout")
        var layoutCalls = 0
        var viewportChecks = 0
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes,
            waitForLayout: {
                layoutCalls += 1
                waitingForLayout.fulfill()
                await layout.wait()
            })
        defer { layout.resolve(()) }
        state.reset()
        state.requestPaging { true }
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }
        state.requestPaging {
            viewportChecks += 1
            return true
        }
        await fulfillment(of: [waitingForLayout], timeout: 2)
        state.requestPaging { XCTFail("Pending layout must not be replaced"); return false }
        XCTAssertEqual(layoutCalls, 1)
        XCTAssertEqual(viewportChecks, 0)
        XCTAssertEqual(sessions.additionalCalls, 0)

        layout.resolve(())
        await fulfillment(of: [next.entered], timeout: 2)
        state.requestPaging { true }
        XCTAssertEqual(viewportChecks, 1)
        XCTAssertEqual(sessions.additionalCalls, 1)
        next.resolve([account(1), account(2)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(changes.insertions, [1..<3])
    }

    func testResetCancelsOldLayoutWithoutClearingReplacementPaging() async throws {
        let initial = PreviewRequest()
        let replacement = PreviewRequest()
        let next = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, replacement], additional: [next])
        let oldLayout = TestGate<Void>()
        let currentLayout = TestGate<Void>()
        defer {
            oldLayout.resolve(())
            currentLayout.resolve(())
            sessions.finishPendingRequests()
        }
        let oldEntered = expectation(description: "Old layout is pending")
        let oldReturned = expectation(description: "Old layout returns after replacement")
        let currentEntered = expectation(description: "Replacement layout is pending")
        var layoutCalls = 0
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes,
            waitForLayout: {
                layoutCalls += 1
                if layoutCalls == 1 {
                    oldEntered.fulfill()
                    await oldLayout.wait()
                    oldReturned.fulfill()
                } else {
                    currentEntered.fulfill()
                    await currentLayout.wait()
                }
            })
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }
        state.requestPaging { XCTFail("Retired layout cannot measure the viewport"); return true }
        await fulfillment(of: [oldEntered], timeout: 2)

        state.reset()
        await finish(replacement, with: [account(3)])
        await expectEventually { changes.initialPages == 2 }
        state.requestPaging { true }
        await fulfillment(of: [currentEntered], timeout: 2)
        oldLayout.resolve(())
        await fulfillment(of: [oldReturned], timeout: 2)
        state.requestPaging { XCTFail("Late layout cannot clear replacement ownership"); return false }
        XCTAssertEqual(layoutCalls, 2)
        XCTAssertEqual(sessions.additionalCalls, 0)
        currentLayout.resolve(())
        await finish(next, with: [account(4)])
        await expectEventually { state.accounts == [self.account(3), self.account(4)] }
        XCTAssertEqual(sessions.requestedPages, [1])
    }

    func testViewportMeasurementCanInvalidateBeforeDerivation() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }
        let previousChanges = changes.values
        let measured = expectation(description: "Viewport layout invalidates the preview")
        state.requestPaging { [weak state] in
            state?.invalidate()
            measured.fulfill()
            return true
        }
        await fulfillment(of: [measured], timeout: 2)
        XCTAssertEqual(state.status, .idle)
        XCTAssertTrue(sessions.created[0].isInvalidated)
        XCTAssertEqual(sessions.additionalCalls, 0)
        XCTAssertEqual(changes.values, previousChanges)
    }

    func testViewportDemandFillsPagesWithoutReenteringRenderingOrMeasurement() async {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let last = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [next, last])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        var rendering = false
        var measuring = false
        let filled = expectation(description: "Viewport stops requesting after it fills")
        weak var observed: AccountPreviewState?
        let state = AccountPreviewState(wallet: wallet(accounts: [account(0)]),
            makeSession: { _ in await sessions.makeSession() },
            timing: .init(now: { .now }, sleepUntil: { _ in try Task.checkCancellation() }),
            didChange: { change in
                XCTAssertFalse(rendering)
                XCTAssertFalse(measuring)
                rendering = true
                defer { rendering = false }
                changes.receive(change)
                switch change {
                case .initialPage, .append:
                    observed?.requestPaging {
                        XCTAssertFalse(rendering)
                        measuring = true
                        defer { measuring = false }
                        observed?.requestPaging { XCTFail("Measurement must coalesce nested layout demand"); return true }
                        let needsMore = (observed?.accounts.count ?? 0) < 3
                        if !needsMore { filled.fulfill() }
                        return needsMore
                    }
                default: break
                }
            })
        observed = state
        state.reset()
        await finish(initial, with: [account(0)])
        await finish(next, with: [account(1)])
        await finish(last, with: [account(2)])
        await fulfillment(of: [filled], timeout: 2)
        XCTAssertEqual(sessions.requestedPages, [1, 2])
        XCTAssertEqual(changes.insertions, [1..<2, 2..<3])
        XCTAssertEqual(state.status, .ready)
    }

    func testDeinitializationCancelsPendingLayoutWithoutRetainingState() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        let layout = TestGate<Void>()
        defer {
            layout.resolve(())
            sessions.finishPendingRequests()
        }
        let entered = expectation(description: "Layout is pending")
        let cancelled = expectation(description: "Pending layout is cancelled")
        let changes = PreviewChanges()
        var state: AccountPreviewState? = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions,
            changes: changes, waitForLayout: {
                await withTaskCancellationHandler {
                    entered.fulfill()
                    await layout.wait()
                } onCancel: { cancelled.fulfill() }
            })
        weak let observed = state
        state?.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }
        state?.requestPaging { XCTFail("Deinitialized preview must not measure its viewport"); return true }
        await fulfillment(of: [entered], timeout: 2)
        state = nil
        XCTAssertNil(observed)
        XCTAssertTrue(sessions.created[0].isInvalidated)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(sessions.additionalCalls, 0)
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
        XCTAssertTrue(sessions.created[0].isInvalidated)
        XCTAssertFalse(sessions.created[1].isInvalidated)

        first.resolve([account(7)])
        await fulfillment(of: [first.returned], timeout: 2)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertTrue(changes.initialPages == 0)
        replacement.resolve([account(0)])
        await expectEventually { changes.initialPages == 1 }
        XCTAssertEqual(state.accounts, [account(0)])
        XCTAssertEqual(sessions.initialCalls, 2)
    }

    func testResetRejectsLateAdditionalPageWithoutClearingTheReplacementLoad() async throws {
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
        await expectEventually { changes.initialPages == 1 }
        state.requestPaging { true }
        await fulfillment(of: [obsolete.entered], timeout: 2)

        state.reset()
        await finish(replacement, with: [account(3)])
        await expectEventually { changes.initialPages == 2 }
        state.requestPaging { true }
        await fulfillment(of: [current.entered, obsolete.cancelled], timeout: 2)
        obsolete.resolve([account(7)])
        await fulfillment(of: [obsolete.returned], timeout: 2)
        state.requestPaging { true }
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
        await expectEventually { changes.initialPages == 1 }
        state.requestPaging { true }
        await fulfillment(of: [next.entered], timeout: 2)
        let previousChanges = changes.values

        state.invalidate()
        XCTAssertTrue(sessions.created[0].isInvalidated)
        await fulfillment(of: [next.cancelled], timeout: 2)
        state.requestPaging { true }
        state.toggle(at: 0)
        next.resolve([account(1)])
        await fulfillment(of: [next.returned], timeout: 2)
        XCTAssertEqual(state.accounts, [account(0)])
        XCTAssertEqual(state.enabledAccounts, [account(0)])
        XCTAssertEqual(changes.values, previousChanges)
        XCTAssertEqual(sessions.additionalCalls, 1)
    }

    func testFailuresRequireExplicitRetryAndRebuildCachedPagesWithoutLosingSelection() async throws {
        let failedInitial = PreviewRequest()
        let initial = PreviewRequest()
        let failedPage = PreviewRequest()
        let rebuiltInitial = PreviewRequest()
        let successfulPage = PreviewRequest()
        let emptyPage = PreviewRequest()
        let sessions = PreviewSessions(
            initial: [failedInitial, initial, rebuiltInitial], additional: [failedPage, successfulPage, emptyPage]
        )
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(8)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(failedInitial, with: nil)
        await expectEventually { state.canRetry }
        XCTAssertEqual(state.status, .failed(page: 0))
        XCTAssertFalse(state.canEdit)
        state.requestPaging { true }
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(8)])
        XCTAssertEqual(sessions.additionalCalls, 0)

        XCTAssertTrue(state.retry(reloadingStore: { XCTFail("A ready store must not be reloaded") }))
        XCTAssertFalse(state.retry(reloadingStore: { XCTFail("A ready store must not be reloaded") }))
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.initialPages == 1 }
        state.toggle(at: 1)
        state.requestPaging { true }
        await finish(failedPage, with: nil)
        await expectEventually { state.canRetry }
        XCTAssertEqual(state.status, .failed(page: 1))
        XCTAssertTrue(sessions.created[1].isInvalidated)
        state.requestPaging { true }
        state.toggle(at: 0)
        XCTAssertEqual(sessions.additionalCalls, 1)
        XCTAssertEqual(state.accounts, [account(0), account(1)])
        XCTAssertEqual(state.enabledAccounts, [account(0), account(1), account(8)])

        XCTAssertTrue(state.retry(reloadingStore: { XCTFail("A ready store must not be reloaded") }))
        await finish(rebuiltInitial, with: [account(0), account(1)])
        await fulfillment(of: [successfulPage.entered], timeout: 2)
        XCTAssertEqual(state.status, .recovering)
        XCTAssertEqual(state.accounts, [account(0), account(1)])
        XCTAssertFalse(state.canEdit)
        successfulPage.resolve([account(8)])
        await expectEventually { changes.initialPages == 2 }
        XCTAssertTrue(changes.insertions.isEmpty)
        XCTAssertEqual(state.accounts, [account(0), account(1), account(8)])
        XCTAssertTrue(state.canEdit)
        XCTAssertTrue(state.hasChanges)
        state.requestPaging { true }
        await finish(emptyPage, with: [])
        await expectEventually { state.status == .ready }
        XCTAssertEqual(sessions.requestedPages, [1, 1, 2])
    }

    func testFailedRecoveryPreservesTheEntireCachedPageRangeAndLateRetryIsSilenced() async throws {
        let initial = PreviewRequest()
        let page = PreviewRequest()
        let failedPage = PreviewRequest()
        let failedRebuild = PreviewRequest()
        let lateRebuild = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, failedRebuild, lateRebuild], additional: [page, failedPage])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.initialPages == 1 }
        state.requestPaging { true }
        await finish(page, with: [account(2)])
        await expectEventually { changes.insertions.count == 1 }
        state.toggle(at: 2)
        state.requestPaging { true }
        await finish(failedPage, with: nil)
        await expectEventually { state.canRetry }
        XCTAssertTrue(state.retry(reloadingStore: { XCTFail("A ready store must not be reloaded") }))
        await finish(failedRebuild, with: nil)
        await expectEventually { state.canRetry }
        XCTAssertEqual(state.status, .failed(page: 2))
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(state.enabledAccounts, [account(0), account(2)])

        XCTAssertTrue(state.retry(reloadingStore: { XCTFail("A ready store must not be reloaded") }))
        await fulfillment(of: [lateRebuild.entered], timeout: 2)
        let priorChanges = changes.values
        state.invalidate()
        lateRebuild.resolve([account(7)])
        await fulfillment(of: [lateRebuild.returned], timeout: 2)
        XCTAssertEqual(changes.values, priorChanges)
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(state.enabledAccounts, [account(0), account(2)])
        XCTAssertFalse(state.canRetry)
        XCTAssertTrue(sessions.created[2].isInvalidated)
    }

    func testStoreFailureRetainsCachedRowsAndCancelsPendingPagination() async throws {
        let initial = PreviewRequest()
        let obsolete = PreviewRequest()
        let replacement = PreviewRequest()
        let recoveredPage = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, replacement], additional: [obsolete, recoveredPage])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.initialPages == 1 }
        state.toggle(at: 1)
        state.requestPaging { true }
        await fulfillment(of: [obsolete.entered], timeout: 2)
        state.reconcileStore(loadState: .failed(.unavailable), isReady: false, wallet: nil)
        XCTAssertFalse(state.canEdit)
        XCTAssertTrue(state.canRetry)
        XCTAssertTrue(sessions.created[0].isInvalidated)
        XCTAssertEqual(state.accounts, [account(0), account(1)])
        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(0)]))
        XCTAssertFalse(changes.values.contains(.close))
        await finish(replacement, with: [account(0), account(1)])
        await fulfillment(of: [recoveredPage.entered], timeout: 2)
        obsolete.resolve([account(7)])
        await fulfillment(of: [obsolete.returned], timeout: 2)
        XCTAssertEqual(state.accounts, [account(0), account(1)])
        recoveredPage.resolve([account(2)])
        await expectEventually { state.status == .ready }
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(state.enabledAccounts, [account(0), account(1)])
    }

    func testStoreRecoveryCallbackInvalidationPreventsRestart() async {
        let original = wallet(accounts: [account(0)])
        let initial = PreviewRequest()
        let recovered = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, recovered])
        defer { sessions.finishPendingRequests() }
        var reenter = false
        weak var observedState: AccountPreviewState?
        let state = AccountPreviewState(
            wallet: original,
            makeSession: { _ in await sessions.makeSession() },
            didChange: { _ in
                guard reenter else { return }
                reenter = false
                observedState?.invalidate()
            }
        )
        observedState = state
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        state.toggle(at: 1)
        state.reconcileStore(loadState: .failed(.unavailable), isReady: false, wallet: nil)

        recovered.entered.isInverted = true
        reenter = true
        state.reconcileStore(loadState: .ready, isReady: true, wallet: original)

        XCTAssertFalse(reenter)
        XCTAssertEqual(state.status, .idle)
        XCTAssertFalse(state.canEdit)
        XCTAssertTrue(sessions.created[0].isInvalidated)
        await fulfillment(of: [recovered.entered], timeout: 0.05)
        XCTAssertEqual(sessions.initialCalls, 1)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(1)])
    }

    func testNestedStoreFailureSurvivesRecoveryNotification() async {
        let original = wallet(accounts: [account(0)])
        let initial = PreviewRequest()
        let recovered = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial, recovered])
        defer { sessions.finishPendingRequests() }
        var reenter = false
        weak var observedState: AccountPreviewState?
        let state = AccountPreviewState(
            wallet: original,
            makeSession: { _ in await sessions.makeSession() },
            didChange: { _ in
                guard reenter else { return }
                reenter = false
                observedState?.reconcileStore(loadState: .failed(.unavailable), isReady: false, wallet: nil)
            }
        )
        observedState = state
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        state.toggle(at: 1)
        state.reconcileStore(loadState: .failed(.unavailable), isReady: false, wallet: nil)

        reenter = true
        state.reconcileStore(loadState: .ready, isReady: true, wallet: original)

        XCTAssertFalse(reenter)
        XCTAssertEqual(state.status, .failed(page: 0))
        XCTAssertFalse(state.canEdit)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(1)])

        state.reconcileStore(loadState: .ready, isReady: true, wallet: original)
        await finish(recovered, with: [account(0), account(1)])
        await expectEventually { state.canEdit }
        XCTAssertEqual(sessions.initialCalls, 2)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(1)])
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
        await expectEventually { changes.initialPages == 1 }
        state.toggle(at: 1)
        let refreshedAccount = account(0, publicKey: "refreshed")
        let refreshed = wallet(accounts: [refreshedAccount])

        state.reconcileStore(loadState: .ready, isReady: true, wallet: refreshed)
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertEqual(state.wallet.accounts, [refreshedAccount])
        XCTAssertTrue(state.hasChanges)
        XCTAssertTrue(state.isEnabled(account(1)))
        XCTAssertEqual(sessions.initialCalls, 1)
        state.toggle(at: 1)
        XCTAssertFalse(state.hasChanges)
        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(0), account(2)]))
        XCTAssertFalse(changes.values.contains(.close))
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
        await expectEventually { changes.initialPages == 1 }
        state.toggle(at: 0)
        state.toggle(at: 1)
        state.requestPaging { true }
        await fulfillment(of: [next.entered], timeout: 2)

        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(0), account(8), account(7)]))
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(7)])
        XCTAssertTrue(state.hasChanges)
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(sessions.initialCalls, 1)
        next.resolve([account(8), account(7), account(3)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8), account(7)])
        state.requestPaging { true }
        await finish(last, with: [account(4)])
        await expectEventually { changes.insertions.count == 2 }
        XCTAssertEqual(sessions.requestedPages, [1, 2])
    }

    func testExternallyFulfilledEditsBecomeCleanAndLaterChangesFollowTheNewBaseline() async throws {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(8)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.initialPages == 1 }
        state.toggle(at: 0)
        state.toggle(at: 1)

        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(1), account(8)]))
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8)])
        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(0), account(8)]))
        XCTAssertFalse(changes.values.contains(.close))
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
        await expectEventually { changes.initialPages == 1 }
        state.toggle(at: 0)

        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(0)]))
        XCTAssertFalse(changes.values.contains(.close))
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

        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(1), account(8)]))
        XCTAssertFalse(changes.values.contains(.close))
        await fulfillment(of: [obsolete.cancelled, replacement.entered], timeout: 2)
        obsolete.resolve([account(0)])
        await fulfillment(of: [obsolete.returned], timeout: 2)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8)])
        replacement.resolve([account(0), account(1)])
        await expectEventually { changes.initialPages == 1 }
        XCTAssertEqual(state.enabledAccounts, [account(1), account(8)])
        XCTAssertFalse(state.hasChanges)
    }

    func testUnchangedRefreshPreservesPendingFirstPageAndItsSession() async throws {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let original = wallet(accounts: [account(0)])
        let state = makeState(wallet: original, sessions: sessions, changes: changes)
        state.reset()
        await fulfillment(of: [initial.entered], timeout: 2)
        let session = try XCTUnwrap(sessions.created.first)
        state.reconcileStore(loadState: .ready, isReady: true, wallet: original)
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertEqual(state.status, .loadingInitial)
        XCTAssertFalse(session.isInvalidated)
        XCTAssertEqual(sessions.initialCalls, 1)
        initial.resolve([account(0), account(1)])
        await fulfillment(of: [initial.returned], timeout: 2)
        await expectEventually { state.canEdit }
        XCTAssertEqual(state.accounts, [account(0), account(1)])
        XCTAssertEqual(changes.initialPages, 1)
        XCTAssertEqual(sessions.initialCalls, 1)
    }

    func testRefreshPreservesFailureUntilExplicitRetryWithTheLatestWallet() async {
        let failed = PreviewRequest()
        let replacement = PreviewRequest()
        let sessions = PreviewSessions(initial: [failed, replacement])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await finish(failed, with: nil)

        await expectEventually { state.canRetry }
        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(1)]))
        XCTAssertFalse(changes.values.contains(.close))
        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(1)]))
        XCTAssertFalse(changes.values.contains(.close))
        XCTAssertEqual(state.status, .failed(page: 0))
        XCTAssertEqual(sessions.initialCalls, 1)
        XCTAssertTrue(state.retry(reloadingStore: { XCTFail("A ready store must not be reloaded") }))
        await finish(replacement, with: [account(0), account(1)])
        await expectEventually { changes.initialPages == 1 }
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
            await expectEventually { changes.initialPages == 1 }
            state.toggle(at: 1)
            let previousChanges = changes.values

            state.reconcileStore(loadState: .ready, isReady: true, wallet: replacement)
            XCTAssertEqual(changes.values, previousChanges + [.close])
            XCTAssertFalse(state.canEdit)
            XCTAssertTrue(sessions.created[0].isInvalidated)
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
        XCTAssertTrue(sessions.created[0].isInvalidated)
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
        state.reconcileStore(loadState: .ready, isReady: true, wallet: wallet(accounts: [account(2)]))
        XCTAssertFalse(changes.values.contains(.close))
        await fulfillment(of: [cancelled, replacementPage.entered], timeout: 2)
        creation.resolve(obsolete)
        await fulfillment(of: [returned], timeout: 2)
        await expectEventually { obsolete.isInvalidated }
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertTrue(changes.initialPages == 0)
        replacementPage.resolve([account(2)])
        await expectEventually { state.accounts == [self.account(2)] }
        XCTAssertEqual(obsoletePage.calls, 0)
        XCTAssertEqual(changes.initialPages, 1)
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
        await expectEventually { session.isInvalidated }
        XCTAssertEqual(initial.calls, 0)
        XCTAssertEqual(changes.values, [.reload])
    }

    func testInvalidationRetiresInitialSessionBeforeTheFirstPageReturns() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes)
        state.reset()
        await fulfillment(of: [initial.entered], timeout: 2)
        XCTAssertFalse(sessions.created[0].isInvalidated)

        state.invalidate()
        XCTAssertTrue(sessions.created[0].isInvalidated)
        await fulfillment(of: [initial.cancelled], timeout: 2)
        initial.resolve([account(0)])
        await fulfillment(of: [initial.returned], timeout: 2)
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertEqual(changes.values, [.reload])
    }

    func testInitialPageCallbackCanRetireTheAdoptedSession() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        weak var observedState: AccountPreviewState?
        let state = AccountPreviewState(
            wallet: wallet(accounts: [account(0)]), makeSession: { _ in await sessions.makeSession() },
            didChange: { change in
                changes.receive(change)
                guard case .initialPage = change else { return }
                observedState?.invalidate()
                XCTAssertTrue(sessions.created[0].isInvalidated)
            }
        )
        observedState = state
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }

        XCTAssertTrue(sessions.created[0].isInvalidated)
        state.toggle(at: 0)
        XCTAssertFalse(state.hasChanges)
    }

    func testDeinitializationRetiresAnIdleInstalledSession() async {
        let initial = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        var state: AccountPreviewState? = makeState(
            wallet: wallet(accounts: [account(0)]), sessions: sessions, changes: changes
        )
        weak let observedState = state
        state?.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }
        XCTAssertFalse(sessions.created[0].isInvalidated)

        state = nil
        XCTAssertNil(observedState)
        XCTAssertTrue(sessions.created[0].isInvalidated)
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
        await expectEventually { changes.initialPages == 1 }
        XCTAssertTrue(clock.registrations.isEmpty)
        clock.advance(by: 100_000_000)
        state.requestPaging { true }
        await expectEventually { clock.pendingSleeps.count == 1 }
        XCTAssertEqual(clock.pendingSleeps.first?.durationNanoseconds, 130_000_000)
        clock.advance(by: 129_000_000)
        XCTAssertEqual(sessions.additionalCalls, 0)
        clock.advance(by: 1_000_000)
        await fulfillment(of: [next.entered], timeout: 2)
        clock.advance(by: 1_000_000_000)
        next.resolve([account(1)])
        await expectEventually { changes.insertions.count == 1 }
        state.requestPaging { true }
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
        let empty = PreviewRequest()
        let sessions = PreviewSessions(initial: [initial], additional: [empty])
        defer { sessions.finishPendingRequests() }
        let changes = PreviewChanges()
        let clock = TestClock()
        let state = makeState(wallet: wallet(accounts: [account(0)]), sessions: sessions,
            changes: changes, timing: timing(clock))
        state.reset()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.initialPages == 1 }
        clock.advance(by: 230_000_000)
        state.requestPaging { true }
        await finish(empty, with: [])
        await expectEventually { state.status == .ready }
        XCTAssertEqual(sessions.requestedPages, [1])
        XCTAssertTrue(clock.registrations.isEmpty)
        let extraPage = expectation(description: "Exhausted session does not derive another page")
        extraPage.isInverted = true
        sessions.onAdditionalRequest = { extraPage.fulfill() }
        clock.advance(by: 1_000_000_000)
        state.requestPaging { true }
        state.requestPaging { true }
        await fulfillment(of: [extraPage], timeout: 0.05)
        XCTAssertEqual(sessions.additionalCalls, 1)
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
        timing: AccountPreviewState.Timing = .init(now: { .now }, sleepUntil: { _ in try Task.checkCancellation() }),
        waitForLayout: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) -> AccountPreviewState {
        AccountPreviewState(wallet: wallet, makeSession: { _ in await sessions.makeSession() }, timing: timing,
            waitForLayout: waitForLayout, didChange: changes.receive)
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

    var initialPages: Int {
        values.filter { $0 == .initialPage }.count
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
    private(set) var created = [PreviewSession]()
    var onAdditionalRequest: (() -> Void)?

    init(initial: [PreviewRequest], additional: [PreviewRequest] = []) {
        self.initial = initial
        self.additional = additional
    }

    func makeSession() -> PreviewSession {
        let index = initialCalls
        initialCalls += 1
        let session = PreviewSession(source: self, initial: initial.indices.contains(index) ? initial[index] : nil)
        created.append(session)
        return session
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
    weak var source: PreviewSessions?
    let initial: PreviewRequest?
    private nonisolated let invalidated = Mutex(false)

    nonisolated var isInvalidated: Bool { invalidated.withLock { $0 } }

    nonisolated func invalidate() { invalidated.withLock { $0 = true } }

    init(source: PreviewSessions, initial: PreviewRequest?) {
        self.source = source
        self.initial = initial
    }

    func previewAccounts(page: Int) async throws -> [WalletAccount] {
        let requested = if page == 0 { initial } else { await source?.additionalRequest(page: page) }
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

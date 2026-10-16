import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class AccountPreviewStateTests: XCTestCase {
    func testSelectionPreservesUndiscoveredAccountsAndOutputOrder() async throws {
        let original = wallet(accounts: [account(8), account(0), account(9)])
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let pager = PreviewPager(initial: [initial], additional: [next])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: original, pager: pager, changes: changes)
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
        let pager = PreviewPager(initial: [initial])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes)
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
        let pager = PreviewPager(initial: [initial], additional: [next])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes)
        state.reset()
        state.loadMore()
        await finish(initial, with: [account(0)])
        await expectEventually { changes.generations.count == 1 }
        state.loadMore()
        XCTAssertEqual(pager.additionalCalls, 0)

        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        state.loadMore()
        state.loadMore()
        await fulfillment(of: [next.entered], timeout: 2)
        state.loadMore()
        XCTAssertEqual(pager.additionalCalls, 1)
        next.resolve([account(1), account(2)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.accounts, [account(0), account(1), account(2)])
        XCTAssertEqual(changes.insertions, [1..<3])
    }

    func testResetRejectsLateFirstPageWithoutClearingTheReplacementLoad() async throws {
        let first = PreviewRequest()
        let replacement = PreviewRequest()
        let pager = PreviewPager(initial: [first, replacement])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes)
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
        XCTAssertEqual(pager.initialCalls, 2)
    }

    func testResetRejectsLateAdditionalPageAndOldLayoutActivation() async throws {
        let initial = PreviewRequest()
        let obsolete = PreviewRequest()
        let replacement = PreviewRequest()
        let current = PreviewRequest()
        let pager = PreviewPager(initial: [initial, replacement], additional: [obsolete, current])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes)
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
        XCTAssertEqual(pager.additionalCalls, 2)
        XCTAssertEqual(state.accounts, [account(3)])
        current.resolve([account(4)])
        await expectEventually { changes.insertions.count == 1 }
        XCTAssertEqual(state.accounts, [account(3), account(4)])
        XCTAssertEqual(changes.insertions, [1..<2])
    }

    func testInvalidationCancelsWorkAndSilencesLateResults() async throws {
        let initial = PreviewRequest()
        let next = PreviewRequest()
        let pager = PreviewPager(initial: [initial], additional: [next])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes)
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
        XCTAssertEqual(pager.additionalCalls, 1)
        XCTAssertEqual(pager.invalidations, 1)
    }

    func testFailuresPreserveSelectionAndAllowLaterPageRetryWithoutEmptyInsertions() async throws {
        let failedInitial = PreviewRequest()
        let initial = PreviewRequest()
        let failedPage = PreviewRequest()
        let successfulPage = PreviewRequest()
        let emptyPage = PreviewRequest()
        let pager = PreviewPager(
            initial: [failedInitial, initial], additional: [failedPage, successfulPage, emptyPage]
        )
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let state = makeState(wallet: wallet(accounts: [account(0), account(8)]), pager: pager, changes: changes)
        state.reset()
        await finish(failedInitial, with: nil)
        state.loadMore()
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertTrue(state.hasEnabledAccounts)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.enabledAccounts, [account(0), account(8)])
        XCTAssertTrue(changes.generations.isEmpty)
        XCTAssertEqual(pager.additionalCalls, 0)

        state.reset()
        await finish(initial, with: [account(0), account(1)])
        await expectEventually { changes.generations.count == 1 }
        state.toggle(at: 1)
        XCTAssertTrue(state.activatePaging(for: try XCTUnwrap(changes.generations.last)))
        state.loadMore()
        await finish(failedPage, with: nil)
        await expectEventually {
            state.loadMore()
            return pager.additionalCalls == 2
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

    func testRefreshKeepsMetadataChangesAndResetsPristineAccountChanges() async throws {
        let initial = PreviewRequest()
        let replacement = PreviewRequest()
        let pager = PreviewPager(initial: [initial, replacement])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        let original = wallet(accounts: [account(0)])
        let state = makeState(wallet: original, pager: pager, changes: changes)
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
        XCTAssertEqual(pager.initialCalls, 1)
        XCTAssertTrue(state.activatePaging(for: generation))
        state.toggle(at: 1)
        XCTAssertFalse(state.hasChanges)
        XCTAssertEqual(state.refresh(wallet: wallet(accounts: [account(0), account(2)])), .keepEditing)
        XCTAssertFalse(state.activatePaging(for: generation))
        XCTAssertTrue(state.accounts.isEmpty)
        XCTAssertFalse(state.hasChanges)
        await finish(replacement, with: [account(0), account(1), account(2)])
        await expectEventually { changes.generations.count == 2 }
        XCTAssertEqual(state.enabledAccounts, [account(0), account(2)])
        XCTAssertEqual(pager.initialCalls, 2)
    }

    func testRefreshClosesDirtyChangesOrRemovedWallets() async throws {
        for removed in [false, true] {
            let initial = PreviewRequest()
            let pager = PreviewPager(initial: [initial])
            defer { pager.finishPendingRequests() }
            let changes = PreviewChanges()
            let state = makeState(wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes)
            state.reset()
            await finish(initial, with: [account(0), account(1)])
            await expectEventually { changes.generations.count == 1 }
            let generation = try XCTUnwrap(changes.generations.last)
            if !removed { state.toggle(at: 1) }
            let previousChanges = changes.values

            XCTAssertEqual(state.refresh(wallet: removed ? nil : wallet(accounts: [account(2)])), .close)
            XCTAssertFalse(state.activatePaging(for: generation))
            XCTAssertEqual(changes.values, previousChanges)
            XCTAssertEqual(pager.initialCalls, 1)
            XCTAssertEqual(pager.invalidations, 1)
        }
    }

    func testLoadingDoesNotRetainStateAndDeinitializationCancelsTheRequest() async {
        let initial = PreviewRequest()
        let pager = PreviewPager(initial: [initial])
        defer { pager.finishPendingRequests() }
        let changes = PreviewChanges()
        var state: AccountPreviewState? = makeState(
            wallet: wallet(accounts: [account(0)]), pager: pager, changes: changes
        )
        weak var weakState = state
        state?.reset()
        await fulfillment(of: [initial.entered], timeout: 2)

        state = nil
        XCTAssertNil(weakState)
        await fulfillment(of: [initial.cancelled], timeout: 2)
        initial.resolve([account(0)])
        await fulfillment(of: [initial.returned], timeout: 2)
        XCTAssertEqual(changes.values, [.reload])
        XCTAssertEqual(pager.invalidations, 1)
    }

    func testReloadCallbackCanInvalidateBeforeTheLoadStarts() {
        let initial = PreviewRequest()
        let pager = PreviewPager(initial: [initial])
        defer { pager.finishPendingRequests() }
        weak var observedState: AccountPreviewState?
        let state = AccountPreviewState(
            wallet: wallet(accounts: [account(0)]), makePager: { _ in pager },
            didChange: { _ in observedState?.invalidate() }
        )
        observedState = state
        state.reset()
        XCTAssertEqual(pager.invalidations, 1)
        XCTAssertEqual(pager.initialCalls, 0)
    }

    private func makeState(
        wallet: WalletSnapshot,
        pager: PreviewPager,
        changes: PreviewChanges
    ) -> AccountPreviewState {
        AccountPreviewState(wallet: wallet, makePager: { _ in pager }, didChange: changes.receive)
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
private final class PreviewPager: AccountPreviewPaging {
    let initial: [PreviewRequest]
    let additional: [PreviewRequest]
    private(set) var initialCalls = 0
    private(set) var additionalCalls = 0
    private(set) var invalidations = 0

    init(initial: [PreviewRequest], additional: [PreviewRequest] = []) {
        self.initial = initial
        self.additional = additional
    }

    func reset() async -> [WalletAccount]? {
        let index = initialCalls
        initialCalls += 1
        guard initial.indices.contains(index) else {
            XCTFail("Unexpected initial-page request")
            return nil
        }
        return await initial[index].run()
    }

    func previewMoreIfNeeded() async -> [WalletAccount]? {
        let index = additionalCalls
        additionalCalls += 1
        guard additional.indices.contains(index) else {
            XCTFail("Unexpected additional-page request")
            return nil
        }
        return await additional[index].run()
    }

    func invalidate() {
        invalidations += 1
    }

    func finishPendingRequests() {
        (initial + additional).forEach { $0.resolve(nil) }
    }
}

private final class PreviewRequest: Sendable {
    let entered = XCTestExpectation(description: "Preview requested")
    let returned = XCTestExpectation(description: "Preview returned")
    let cancelled = XCTestExpectation(description: "Preview cancelled")
    private let result = TestGate<[WalletAccount]?>()

    func run() async -> [WalletAccount]? {
        await withTaskCancellationHandler {
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

import Foundation
import Synchronization
import XCTest
@testable import WalletAuthority
import WalletDomain
import WalletRuntimeTestSupport

final class RevocationLedgerCapacityTests: XCTestCase {
    private enum Failure: Error { case injected }

    private let originalEpoch = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!
    private let replacementEpoch = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174001")!
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-capacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        rootURL = nil
    }

    func testEntryCapacityRolloverPublishesTheWholeBatchBeforeSourceCommit() throws {
        let original = try seed(walletCount: WalletAuthorityRevocationLedger.maximumEntries)
        let account = descriptor(walletID: "new-account-wallet")
        let removals: [WalletAuthorityRemoval] = [.wallet(id: "new-wallet"), .accounts([account])]
        let events = LockedTestValue([String]())
        let ledgerURL = ledgerURL
        let store = makeStore { io in
            let baseIO = io
            io.replace = { data, url in
                events.withValue { $0.append("publish") }
                try baseIO.replace(data, url)
            }
        }
        try store.perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: removals)
        }, beforeCommit: {
            events.withValue { $0.append("beforeCommit") }
            XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
        }, commit: { _ in
            events.withValue { $0.append("commit") }
            let published = try storedLedger()
            XCTAssertEqual(published.epoch, replacementEpoch)
            XCTAssertEqual(published.sequence, 1)
            XCTAssertEqual(published.walletRemovals, [.init(walletID: "new-wallet", sequence: 1)])
            XCTAssertEqual(published.accountRemovals, [.init(account: account, sequence: 1)])
        })
        XCTAssertEqual(events.value, ["beforeCommit", "publish", "commit"])
    }

    func testByteCapacityRolloverKeepsTheCompleteCurrentBatch() throws {
        _ = try seed(walletCount: 25_000, longIDs: true)
        let removals = (25_000..<33_000).map {
            WalletAuthorityRemoval.wallet(id: walletID($0, long: true))
        }
        try mutate(removals)
        let published = try storedLedger()
        XCTAssertEqual(published.epoch, replacementEpoch)
        XCTAssertEqual(published.sequence, 1)
        XCTAssertEqual(published.walletRemovals.count, removals.count)
        XCTAssertEqual(Set(published.walletRemovals.map(\.walletID)), Set((25_000..<33_000).map { walletID($0, long: true) }))
        XCTAssertLessThanOrEqual(try Data(contentsOf: ledgerURL).count, WalletAuthorityRevocationLedger.maximumEncodedBytes)
    }

    func testCoalescingAtCapacityKeepsTheExistingEpoch() throws {
        _ = try seed(walletCount: WalletAuthorityRevocationLedger.maximumEntries)
        try mutate([.wallet(id: walletID(0, long: false))])
        let published = try storedLedger()
        XCTAssertEqual(published.epoch, originalEpoch)
        XCTAssertEqual(published.sequence, 2)
        XCTAssertEqual(published.walletRemovals.count, WalletAuthorityRevocationLedger.maximumEntries)
    }

    func testBatchThatCannotFitAnEmptyLedgerHasNoCommitSideEffects() throws {
        let original = try seed(walletCount: 1)
        let callbacks = LockedTestValue(0)
        let oversized = (0...WalletAuthorityRevocationLedger.maximumEntries).map {
            WalletAuthorityRemoval.wallet(id: "new-\($0)")
        }
        XCTAssertThrowsError(try makeStore().perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: oversized)
        }, beforeCommit: {
            callbacks.increment()
        }, commit: { _ in
            callbacks.increment()
        }))
        XCTAssertEqual(callbacks.value, 0)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
    }

    func testByteOversizedBatchHasNoCommitSideEffects() throws {
        let original = try seed(walletCount: 1)
        let callbacks = LockedTestValue(0)
        let oversized = (0..<33_000).map { WalletAuthorityRemoval.wallet(id: walletID($0, long: true)) }
        XCTAssertThrowsError(try makeStore().perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: oversized)
        }, beforeCommit: {
            callbacks.increment()
        }, commit: { _ in
            callbacks.increment()
        }))
        XCTAssertEqual(callbacks.value, 0)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
    }

    func testOversizedStoredLedgerIsUnavailableWithoutResettingItsHistory() throws {
        let cases = [
            Data(repeating: 0, count: WalletAuthorityRevocationLedger.maximumEncodedBytes + 1),
            try PropertyListSerialization.data(fromPropertyList: [
                "schemaVersion": 1, "epoch": originalEpoch.uuidString, "sequence": 1,
                "walletRemovals": Array(repeating: ["walletID": "old-wallet", "sequence": 1] as [String: Any],
                    count: WalletAuthorityRevocationLedger.maximumEntries + 1),
                "accountRemovals": [],
            ] as [String: Any], format: .binary, options: 0),
        ]
        for original in cases {
            try original.write(to: ledgerURL)
            let callbacks = LockedTestValue(0)
            for _ in 0..<2 {
                let store = makeStore()
                XCTAssertThrowsError(try store.perform(preparing: {
                    PreparedWalletSourceMutation(payload: (), authorityRemovals: [.wallet(id: "new-wallet")])
                }, beforeCommit: {
                    callbacks.increment()
                }, commit: { _ in
                    callbacks.increment()
                }))
                guard case .unavailable = store.configurationSnapshot(
                    configurationKey: "https://wallet.example", profileIdentifier: nil
                ) else { return XCTFail("Oversized history must not recover as an empty epoch") }
                XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
            }
            XCTAssertEqual(callbacks.value, 0)
        }
    }

    func testFailedAndUncertainRolloverPublicationPreventSourceCommit() throws {
        for afterWrite in [false, true] {
            let original = try seed(walletCount: WalletAuthorityRevocationLedger.maximumEntries)
            let committed = LockedTestValue(false)
            let store = makeStore { io in
                let baseIO = io
                io.replace = { data, url in
                    if afterWrite { try baseIO.replace(data, url) }
                    throw Failure.injected
                }
                io.synchronizePublishedFile = { _ in throw Failure.injected }
            }
            XCTAssertThrowsError(try store.perform(preparing: {
                PreparedWalletSourceMutation(payload: (), authorityRemovals: [.wallet(id: "new-wallet")])
            }, beforeCommit: {}, commit: { _ in committed.value = true }))
            XCTAssertFalse(committed.value)
            if afterWrite {
                XCTAssertEqual(try storedLedger().epoch, replacementEpoch)
            } else {
                XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
            }
        }
    }

    func testFailureAfterPublishedRolloverKeepsTheNewEpoch() throws {
        _ = try seed(walletCount: WalletAuthorityRevocationLedger.maximumEntries)
        XCTAssertThrowsError(try makeStore().perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: [.wallet(id: "new-wallet")])
        }, beforeCommit: {}, commit: { _ in throw Failure.injected }))
        let published = try storedLedger()
        XCTAssertEqual(published.epoch, replacementEpoch)
        XCTAssertEqual(published.walletRemovals, [.init(walletID: "new-wallet", sequence: 1)])
    }

    func testRolloverRequiresADifferentEpoch() throws {
        let original = try seed(walletCount: WalletAuthorityRevocationLedger.maximumEntries)
        let callbacks = LockedTestValue(0)
        let sameEpoch = originalEpoch
        let store = ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL,
            dependencies: .init(revocationEpoch: { sameEpoch }))
        XCTAssertThrowsError(try store.perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: [.wallet(id: "new-wallet")])
        }, beforeCommit: { callbacks.increment() }, commit: { _ in callbacks.increment() }))
        XCTAssertEqual(callbacks.value, 0)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
    }

    func testConcurrentWritersNearCapacityObserveTheirWholePublishedBatch() throws {
        _ = try seed(walletCount: WalletAuthorityRevocationLedger.maximumEntries - 1)
        let root = try XCTUnwrap(rootURL)
        let ledgerURL = ledgerURL
        let replacement = replacementEpoch
        let results = LockedTestValue([Int: UUID]())
        let errors = LockedTestValue([String]())
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let store = ExtensionRequestFileStore(rootURL: root, directoryBoundary: root,
                dependencies: .init(revocationEpoch: { replacement }, crossProcessLockTimeoutNanoseconds: 30_000_000_000))
            do {
                try store.perform(preparing: {
                    PreparedWalletSourceMutation(payload: index, authorityRemovals: [.wallet(id: "new-\(index)")])
                }, beforeCommit: {}, commit: { writer in
                    guard let published = try WalletAuthorityRevocationLedger.decode(Data(contentsOf: ledgerURL)),
                          published.walletRemovals.contains(where: { $0.walletID == "new-\(writer)" }) else {
                        errors.withValue { $0.append("Missing published batch for \(writer)") }
                        return
                    }
                    results.withValue { $0[writer] = published.epoch }
                })
            } catch { errors.withValue { $0.append(String(describing: error)) } }
        }
        XCTAssertTrue(errors.value.isEmpty, "\(errors.value)")
        XCTAssertEqual(results.value.count, 8)
        XCTAssertEqual(results.value.values.filter { $0 == originalEpoch }.count, 1)
        XCTAssertEqual(results.value.values.filter { $0 == replacementEpoch }.count, 7)
        let published = try storedLedger()
        XCTAssertEqual(published.epoch, replacementEpoch)
        XCTAssertEqual(published.sequence, 7)
        XCTAssertEqual(published.walletRemovals.count, 7)
    }

    private var ledgerURL: URL { rootURL.appendingPathComponent("wallet-authority-revocations.state") }

    private func makeStore(
        configure: (inout ExtensionRequestStoreFiles.IO) -> Void = { _ in }
    ) -> ExtensionRequestFileStore {
        let replacement = replacementEpoch
        return ExtensionRequestFileStore(rootURL: rootURL, directoryBoundary: rootURL, dependencies: .init(
            revocationEpoch: { replacement }, fileIO: approvalStoreIO(directoryBoundary: rootURL, configure: configure)
        ))
    }

    private func seed(walletCount: Int, longIDs: Bool = false) throws -> Data {
        var ledger = WalletAuthorityRevocationLedger(epoch: originalEpoch)
        try ledger.record((0..<walletCount).map { .wallet(id: walletID($0, long: longIDs)) })
        let data = try ledger.encoded()
        try data.write(to: ledgerURL)
        return data
    }

    private func storedLedger() throws -> WalletAuthorityRevocationLedger {
        try XCTUnwrap(WalletAuthorityRevocationLedger.decode(Data(contentsOf: ledgerURL)))
    }

    private func mutate(_ removals: [WalletAuthorityRemoval]) throws {
        try makeStore().perform(preparing: {
            PreparedWalletSourceMutation(payload: (), authorityRemovals: removals)
        }, beforeCommit: {}, commit: { _ in })
    }

    private func walletID(_ index: Int, long: Bool) -> String {
        (long ? String(repeating: "x", count: 240) : "wallet-") + String(index)
    }

    private func descriptor(walletID: String) -> WalletAccountDescriptor {
        WalletAccountDescriptor(walletID: walletID, coin: .ethereum,
            normalizedAddress: "0x0000000000000000000000000000000000000001", derivationPath: "m/44'/60'/0'/0/0")
    }
}
